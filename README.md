# serverless-secure-codepipeline

A self-referential, security-hardened CI/CD pipeline: a GitHub webhook
triggers a Lambda that verifies the request's HMAC signature and
starts a CodePipeline execution, which builds and deploys this
repo's own webhook handler code through a dev → manual approval →
prod flow.

## Why "self-referential"
Rather than deploying a separate sample application, this pipeline
builds and deploys **its own webhook handler**. The goal is to
demonstrate CI/CD mechanics — build, deploy, gate, promote, detect,
roll back — without a throwaway payload to explain. `cicd-pipeline-
webhook-handler-prod` exists purely as a promotion target for the
approval gate and the incident simulation below; it is not wired to
any external traffic.

## Architecture

```
GitHub push (main)
      │
      ▼
API Gateway (HTTP API) ──▶ Lambda: webhook handler
                                │  • verifies X-Hub-Signature-256
                                │    (HMAC-SHA256, constant-time
                                │    comparison)
                                │  • filters: push events to main only
                                │  • reads shared secret from
                                │    Secrets Manager
                                ▼
                        CodePipeline: cicd-pipeline
                                │
                    ┌───────────┼────────────────────────┐
                    ▼           ▼                        ▼
                 Source      Build                 DeployDev
             (CodeStar    (CodeBuild:          (CodeBuild:
              Connection    package Lambda      update dev
              to GitHub)    zip artifact)        Lambda code)
                                                       │
                                                       ▼
                                              ApprovalGate
                                          (SNS/email notification,
                                           approve via CodePipeline
                                           console link)
                                                       │
                                                       ▼
                                               DeployProd
                                          (CodeBuild: update prod
                                           Lambda code)
```

## Components

| Component | What it does |
|---|---|
| `src/webhook_handler/` | Python Lambda: HMAC verification + pipeline trigger |
| `modules/webhook-receiver/` | API Gateway + Lambda + DLQ + IAM (Terraform) |
| `modules/pipeline/` | CodeStar Connection, artifact bucket, CodeBuild ×3, CodePipeline, prod Lambda |
| `modules/approval-gate/` | SNS topic + email subscription wired to the pipeline's manual approval stage |
| `environments/dev/` | Root Terraform config for this project's single environment |
| `docs/adr/` | Architecture decision records |
| `docs/security/scan-exceptions.md` | Every accepted Checkov/Trivy finding, with reasoning |
| `docs/postmortem.md` | Deliberate incident simulation: break, detect, roll back, root-cause |

## Security

- **Least privilege throughout.** Deployment uses a dedicated IAM
  Identity Center permission set (`CICDPolicyDeploy`), not an admin
  identity — scoped per-resource-type, built up incrementally as each
  new AWS service was introduced (see ADR 002).
- **HMAC signature verification** on every webhook delivery, using
  `hmac.compare_digest` to avoid timing attacks — not a bare `==`
  comparison.
- **Secrets Manager**, not GitHub Secrets, for the webhook's shared
  secret — GitHub Secrets are only ever injected into GitHub Actions
  runs and are not readable by a Lambda at invocation time (ADR 001).
- **Checkov + Trivy** scan every push (Terraform config and the
  GitHub Actions workflow itself). Every accepted finding is
  documented in `docs/security/scan-exceptions.md` with a specific,
  resource-level reason — nothing is silently suppressed.

## Known limitations

- **This pipeline deploys code, not infrastructure.** The
  DeployDev/DeployProd stages run `aws lambda update-function-code`
  against a build artifact — they do **not** run `terraform apply`.
  A Terraform-managed change (an environment variable, an IAM policy,
  a new resource) is not deployed by this pipeline; it requires a
  manual `terraform apply` by design. This was discovered directly
  during the incident simulation (`docs/postmortem.md`) and is called
  out explicitly here rather than left implicit.
- **CI does not run `terraform plan`.** An earlier attempt to add a
  `terraform-plan` job authenticated via GitHub Actions OIDC hit a
  persistent, unresolved `AssumeRoleWithWebIdentity: AccessDenied`
  error despite an independently-verified-correct trust policy (see
  ADR 003). CI scope was reduced to Checkov + Trivy only; `plan`/
  `apply` are run locally via SSO.
- **Lambda concurrency limits are not set.** This AWS account's
  default Lambda concurrency quota (10 total / 10 unreserved) makes
  any `reserved_concurrent_executions` value infeasible without a
  quota increase — documented as an accepted exception rather than
  forcing a value the API would reject.

## Setup

1. Create the Secrets Manager secret and populate it with a shared
   HMAC secret (`openssl rand -hex 32`):
   ```bash
   export TF_VAR_webhook_secret_value="<generated secret>"
   ```
2. Apply the Terraform config:
   ```bash
   cd environments/dev
   terraform init -backend-config=backend.hcl
   terraform plan -out=tfplan
   terraform apply tfplan
   ```
3. Authorize the CodeStar Connection (one-time manual step — Terraform
   cannot complete OAuth handshakes): AWS Console → Developer Tools →
   Settings → Connections → find the pending connection → "Update
   pending connection" → authorize via GitHub.
4. Configure the GitHub webhook: repo Settings → Webhooks → Add
   webhook, using the `webhook_url` Terraform output as the payload
   URL, the same secret from step 1, content type `application/json`,
   event: "Just the push event."
5. Confirm the SNS email subscription for the approval gate (check
   the inbox for the address supplied as `approval_notification_email`
   and click the confirmation link).

## Decision records

See `docs/adr/` for the reasoning behind:
- **001** — webhook secret storage (Secrets Manager over GitHub Secrets/SSM)
- **002** — least-privilege deploy role design and the `iam:PassRole` scoping fix
- **003** — dropping the CI `terraform-plan` job after an unresolved OIDC issue