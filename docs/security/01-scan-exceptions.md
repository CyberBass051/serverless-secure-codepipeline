# Checkov Scan Exceptions

This document tracks Checkov findings that are intentionally not
remediated, with the reasoning for each. Every exception listed here
is also suppressed inline in the relevant `.tf` file with a matching
`checkov:skip` comment, so the CI scan passes honestly rather than by
having its bar silently lowered.

---

## CKV_AWS_117 — Lambda not configured inside a VPC
**Resource:** `module.webhook_receiver.aws_lambda_function.webhook_handler`

**Accepted.** Placing this Lambda in a VPC would require a NAT Gateway
(~$32/month) or VPC endpoints for it to still reach Secrets Manager and
CodePipeline's public API endpoints — added cost and complexity with
no corresponding security benefit for a function whose entire job is
receiving public webhook traffic. VPC placement matters for functions
accessing private resources (RDS, internal services); this one doesn't.

## CKV_AWS_309 — API Gateway route has no authorization type
**Resource:** `module.webhook_receiver.aws_apigatewayv2_route.webhook_post`

**Accepted.** GitHub webhook deliveries cannot authenticate via IAM or
JWT — GitHub has no mechanism to attach AWS SigV4 or a bearer token to
outbound webhook requests. Authentication is instead enforced inside
the Lambda handler via HMAC-SHA256 signature verification
(`X-Hub-Signature-256`, compared with `hmac.compare_digest` to avoid
timing attacks) against a secret shared only between GitHub and this
project's Secrets Manager entry. `authorization_type = "NONE"` at the
route level is correct, not an oversight — the auth boundary is
application-level, not transport-level. Same pattern as the accepted
public-ALB-ingress finding in `wazuh-auto-scaling`.

## CKV_AWS_272 — Lambda code-signing not configured
**Resource:** `module.webhook_receiver.aws_lambda_function.webhook_handler`

**Accepted.** Code signing (AWS Signer, signing profiles, a signing
job pipeline) is meaningful for organizations with multiple developers
deploying to shared production Lambdas, where you need cryptographic
proof of *who* built and shipped a given artifact. For a single-
maintainer portfolio project, the operational overhead of standing up
a signing profile isn't justified by the risk it mitigates here.
Revisit if this project ever has more than one contributor.

## CKV_AWS_149 — Secrets Manager secret not encrypted with a KMS CMK
**Resource:** `aws_secretsmanager_secret.github_webhook`

**Accepted.** Secrets Manager encrypts all secrets at rest using AWS's
default `aws/secretsmanager` KMS key regardless of whether a customer-
managed key (CMK) is specified. A CMK adds key-policy-level access
control and independent audit trail for key usage — valuable for
compliance regimes (e.g., requiring customer-controlled key rotation
or explicit key-level IAM boundaries) but disproportionate overhead
for a single secret in a demo project with no compliance driver.

## CKV_AWS_158 — CloudWatch Log Group not encrypted with a KMS CMK
**Resource:** `module.webhook_receiver.aws_cloudwatch_log_group.api_gw`

**Accepted.** Same reasoning as CKV_AWS_149/CKV_AWS_173 — CloudWatch
Logs encrypts at rest by default using AWS-managed keys. A
customer-managed CMK would add key-policy-level access control, but
this log group contains API Gateway access logs (request IDs, source
IPs, status codes) — operational metadata, not secrets or sensitive
payload content — so the added overhead of a CMK isn't justified here.

## CKV_AWS_173 — Lambda environment variables not encrypted with a KMS CMK
**Resource:** `module.webhook_receiver.aws_lambda_function.webhook_handler`

**Accepted.** Same reasoning as CKV_AWS_149 — Lambda environment
variables are encrypted at rest by default using AWS-managed keys.
Also worth noting: the environment variables here
(`WEBHOOK_SECRET_ARN`, `PIPELINE_NAME`) are non-sensitive references
and identifiers, not the secret value itself — the actual HMAC secret
is fetched at invocation time via `secretsmanager:GetSecretValue`, never
stored as a plaintext environment variable.

## CKV2_AWS_57 — Secrets Manager secret has no automatic rotation
**Resource:** `aws_secretsmanager_secret.github_webhook`

**Accepted, documented follow-up.** Already noted as a known gap in
[ADR 001](../adr/001-webhook-secret-storage.md) at the time the
storage decision was made. Manual rotation only, for now. Automatic
rotation would require a rotation Lambda that also updates the
corresponding secret on the GitHub webhook configuration side, which
GitHub's API supports but which is out of scope for this project's
current stage.

---

## Remediated (not exceptions — fixed directly)

For contrast, these findings from the same scan were fixed rather than
accepted, since they were either cheap or represented a real gap
rather than a legitimate design tradeoff:

- **CKV_AWS_116** (no DLQ) — added an SQS dead-letter queue.
- **CKV_AWS_50** (no X-Ray tracing) — enabled active tracing.
- **CKV_AWS_115** (no concurrency limit) — set
  `reserved_concurrent_executions = 5` to bound cost and blast radius
  from a flood of malformed or malicious webhook POSTs.
- **CKV_AWS_76** (no API Gateway access logging) — added a CloudWatch
  Logs destination and access log format on the `$default` stage.
- **CKV2_GHA_1** (GitHub Actions top-level `permissions: write-all`)
  — set explicit least-privilege `permissions` at the workflow and
  per-job level in `security-scan.yml`.
