# Postmortem: Broken Webhook Secret ARN

## Summary
A deliberately introduced configuration error pointed the webhook
Lambda's `WEBHOOK_SECRET_ARN` environment variable at a
plausible-but-nonexistent Secrets Manager secret ARN, causing every
invocation to fail with an unhandled exception.

## Timeline (UTC)
- **2026-07-27T20:04:09** — `terraform apply` completes, deploying
  `WEBHOOK_SECRET_ARN = ...github-webhook-secret-BROKEN` to the live
  Lambda (3 resources changed: Lambda, its IAM policy, and the
  CodePipeline resource that references it).
- **2026-07-27T20:04:10** — First invocation after deploy fails
  immediately: `FunctionError: "Unhandled"`,
  `AccessDeniedException` from Secrets Manager.
- **2026-07-27T20:04:40** — Second invocation, same failure —
  confirms the failure is deterministic, not transient.
- **Same session, following revert** — `git revert` + push restores
  the correct ARN in Terraform config; `terraform apply` deploys the
  fix to the live Lambda (2 resources changed).
- **Confirmed resolved** — fresh invocation returns the correct,
  expected `401 Invalid signature` for the same test payload used
  throughout — matching pre-incident behavior exactly.

## Impact
Simulated on a feature branch first, then merged to `main` and
applied to the real dev Lambda (the same one the live GitHub webhook
targets) via a manual, local `terraform apply`. Because the pipeline's
DeployDev stage only updates Lambda *code* (`aws lambda
update-function-code`), the infrastructure-level change never went
through the pipeline at all — see "Secondary Finding" below. A real
GitHub push during the incident window would have hit the broken
Lambda; no real webhook traffic was confirmed to have done so during
this window.

## Detection
CloudWatch/direct invocation showed:

AccessDeniedException: User: .../cicd-pipeline-webhook-handler is not
authorized to perform: secretsmanager:GetSecretValue on resource:
arn:...secret:cicd-pipeline/github-webhook-secret-BROKEN because no
identity-based policy allows the secretsmanager:GetSecretValue action

Detection method was a direct, synchronous `aws lambda invoke` — not
the Dead Letter Queue. The DLQ only receives events from
**asynchronous** invocations (SNS, EventBridge, etc.) after Lambda's
internal retries are exhausted; a synchronous invoke (direct CLI call,
or API Gateway's proxy integration) returns the error straight to the
caller instead. The DLQ was checked and, correctly, found empty — this
failure mode was never going to reach it. CloudWatch Logs (via direct
invoke output) was the only viable detection path for this class of
error.

## Root Cause
Two contributing factors, both worth noting:
1. `get_webhook_secret()` in `handler.py` has no try/except around the
   Secrets Manager call — any invalid or misconfigured ARN produces an
   unhandled exception rather than a graceful, logged error response.
2. The failure surfaced as `AccessDeniedException`, not
   `ResourceNotFoundException` — because the Lambda's IAM policy
   scopes `secretsmanager:GetSecretValue` to the *original* secret's
   specific ARN. The broken ARN never matched that resource pattern,
   so IAM denied the call before Secrets Manager even checked whether
   the secret existed. A tighter least-privilege policy produced a
   more precise (if initially less obvious) error signal than a
   broader policy would have.

## Fix
`git revert` of the config change, followed by a manual
`terraform apply` to push the corrected ARN to the live Lambda.

## Secondary Finding: infra/code deploy split
Pushing the broken commit to `main` did **not** actually break the
live Lambda on its own — the pipeline's DeployDev stage only runs
`aws lambda update-function-code`, which updates code, not
Terraform-managed configuration like environment variables. The
Lambda only broke once `terraform apply` was run manually. This is a
real gap worth stating plainly: **infrastructure config can drift
independently of the code-deploy pipeline**, since nothing in this
pipeline runs `terraform apply`. A config-level regression could sit
deployed-but-not-live indefinitely if no one applies it, or could be
applied by someone unaware the pipeline "doesn't cover this."

## Lessons / Follow-ups
- A `terraform plan` step in CI (attempted earlier in this project,
  ultimately dropped due to an unresolved OIDC issue — see ADR 003)
  would have surfaced this exact change as a visible diff before
  merge, likely catching it pre-deploy.
- Consider wrapping `get_webhook_secret()` in a try/except that logs
  the specific Secrets Manager error and returns a clean `500` rather
  than letting the raw exception and stack trace propagate.
- Consider a smoke-test stage (scripted invoke + assert on response)
  between DeployDev and the approval gate, to catch this class of
  regression automatically rather than relying on manual invocation.
- Document explicitly, in the pipeline's own README, that
  Terraform-managed infrastructure changes are **not** deployed by
  this pipeline — only Lambda code is. Config changes require a
  manual `terraform apply` by design, and that should be stated
  rather than left implicit.