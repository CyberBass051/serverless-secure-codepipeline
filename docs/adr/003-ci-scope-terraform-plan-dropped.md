# ADR 003: Dropped Automated `terraform plan` from CI

## Status
Accepted

## Context
CI was extended to run `terraform plan` via GitHub Actions OIDC
federation, authenticating as a dedicated least-privilege role
(`cicd-pipeline-github-actions-plan`) rather than long-lived
credentials. Despite extensive verification — trust policy content
confirmed correct against actual token claims via CloudTrail,
`job_workflow_ref` condition matched byte-for-byte, OIDC provider
thumbprint set and then reset, permissions boundary confirmed absent,
account confirmed standalone (ruling out Organization-level SCPs),
and a full destroy/recreate of the OIDC provider and role — the
GitHub Actions job consistently failed with
`AssumeRoleWithWebIdentity: AccessDenied` and a generic
`errorMessage: "An unknown error occurred"` from CloudTrail, with no
further diagnosable detail surfaced by the AWS CLI/SDK layer.

## Decision
The `terraform-plan` CI job, and the OIDC provider/role it depended
on, have been removed. Terraform `plan`/`apply` continue to run
locally, authenticated via the `pietrocorp-cicd-pipeline` IAM
Identity Center permission set (`CICDPolicyDeploy`) over SSO — a
separate, already-working least-privilege identity distinct from the
CI/OIDC path.

CI is scoped to Checkov and Trivy (config scan) only, gated behind
`terraform fmt -check` and `terraform validate` — providing security
and syntax validation on every push/PR without requiring cloud
credentials in the CI environment at all.

## Consequences
- No automated drift/plan visibility on pull requests. Infrastructure
  changes are reviewed via local `plan` output before `apply`, not
  via a CI-generated plan artifact on the PR itself.
- No long-lived or federated AWS credentials exist in GitHub Actions
  for this project, which is arguably a stronger security posture
  than a working-but-broad CI deploy role would have been.
- If OIDC-based CI deployment is revisited later, the root cause of
  this `AccessDenied` was never conclusively identified despite
  thorough investigation (see CloudTrail excerpts and troubleshooting
  history for the full chain); a fresh attempt should consider
  opening an AWS Support case early rather than repeating the same
  diagnostic path.