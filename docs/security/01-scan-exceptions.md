# Checkov / Trivy Scan Exceptions

This document tracks security scan findings that are intentionally
not remediated, with reasoning for each. Every exception here is also
suppressed inline in the relevant `.tf` file with a matching
`checkov:skip` or `#trivy:ignore` comment, so CI passes honestly
rather than by having its bar silently lowered.

---

## Lambda functions (webhook receiver — dev and prod)
**Resources:** `module.webhook_receiver.aws_lambda_function.webhook_handler`,
`module.pipeline.aws_lambda_function.webhook_handler_prod`

### CKV_AWS_117 — Not configured inside a VPC
**Accepted.** Both functions are public-facing or promotion-target
demo functions; VPC placement would require a NAT Gateway or VPC
endpoints for no corresponding security benefit.

### CKV_AWS_173 — Environment variables not encrypted with a KMS CMK
**Accepted.** Environment variables (`WEBHOOK_SECRET_ARN`,
`PIPELINE_NAME`) are non-sensitive identifiers, not secrets. AWS-managed
encryption at rest is sufficient.

### CKV_AWS_272 — Code-signing not configured
**Accepted.** Single-maintainer project; code-signing overhead
(signing profiles, a signing pipeline) isn't justified without
multiple contributors.

### CKV2_AWS_57 — Secrets Manager secret has no automatic rotation
**Accepted, documented follow-up.** See [ADR 001](../adr/001-webhook-secret-storage.md).
Manual rotation only, for now.

### CKV_AWS_149 / CKV_AWS_173 (secret + env vars) — Not encrypted with a KMS CMK
**Accepted.** AWS-managed keys encrypt Secrets Manager and Lambda env
vars by default; a CMK's key-policy control isn't justified here.

### CKV_AWS_309 — API Gateway route has no authorization type
**Accepted.** GitHub webhooks can't use IAM/JWT auth. Authentication
is enforced inside the Lambda via HMAC-SHA256 signature verification.

### CKV_AWS_158 — API Gateway CloudWatch Log Group not KMS-encrypted
**Accepted.** Log group holds access-log metadata (request IDs,
source IPs, status codes), not sensitive content.

### CKV_AWS_27 — DLQ (SQS) not encrypted with a KMS CMK
**Accepted** (dev and prod DLQs). SSE-SQS (AWS-owned key) is
sufficient for queues holding only failed invocation metadata.

---

## Pipeline artifact bucket
**Resource:** `module.pipeline.aws_s3_bucket.pipeline_artifacts`

### CKV_AWS_145 / AVD-AWS-0132 — Not encrypted with a KMS CMK
**Accepted.** Bucket holds build artifacts (source code zips), not
secrets. AWS-managed SSE-S3 is sufficient.

### CKV_AWS_18 — No access logging enabled
**Accepted.** Would require a separate logging-destination bucket;
disproportionate for a build-artifact-only bucket.

### CKV2_AWS_62 — No event notifications enabled
**Accepted.** No event-driven use case for this bucket.

### CKV_AWS_144 — No cross-region replication
**Accepted.** Single-region demo project, no DR requirement.

---

## CodePipeline
**Resource:** `module.pipeline.aws_codepipeline.this`

### CKV_AWS_219 — Artifact store not using a KMS CMK
**Accepted.** Same reasoning as the artifact bucket's own KMS
findings — it's the same underlying bucket.

---

## CodeBuild projects
**Resources:** `module.pipeline.aws_codebuild_project.build`,
`.deploy_dev`, `.deploy_prod`

### CKV_AWS_147 — Not encrypted with a KMS CMK
**Accepted.** Projects handle build logs and source-code artifacts,
not secrets.

## CKV_AWS_115 — No function-level concurrency limit (both Lambdas)
**Resources:** `module.webhook_receiver.aws_lambda_function.webhook_handler`,
`module.pipeline.aws_lambda_function.webhook_handler_prod`

**Accepted.** This AWS account's default Lambda concurrency quota is
10 total executions, and AWS enforces a hard floor of 10 unreserved
executions account-wide — meaning no function in this account can
be assigned any reserved concurrency without first requesting a
service quota increase. Reserving concurrency for either function
under the current quota would be rejected by the API. A quota
increase request has not yet been submitted; this exception
should be revisited once the account limit is raised.

## AVD-AWS-0136 — SNS topic not encrypted with a customer-managed KMS key
**Resource:** `module.approval_gate.aws_sns_topic.approval`

**Accepted.** This topic only carries manual-approval notification
messages (pipeline stage name, a CodePipeline console link) — no
secrets or sensitive payloads. AWS-managed key encryption
(`alias/aws/sns`, satisfies CKV_AWS_26) is sufficient; a
customer-managed CMK's key-policy overhead isn't justified here, same
reasoning as the artifact bucket, CodeBuild projects, and CodePipeline
findings elsewhere in this project.

---

## Remediated (fixed directly, not exceptions)

- **CKV_AWS_116** (no DLQ) — SQS dead-letter queues added to both
  Lambdas.
- **CKV_AWS_50** (no X-Ray tracing) — active tracing enabled on both
  Lambdas.
- **CKV_AWS_115** (no concurrency limit) — `reserved_concurrent_executions`
  set on both Lambdas.
- **CKV_AWS_76** (no API Gateway access logging) — CloudWatch Logs
  destination and access log format added.
- **CKV2_GHA_1** (GitHub Actions top-level `permissions: write-all`)
  — explicit least-privilege `permissions` set at workflow and
  per-job level.
- **CKV2_AWS_61** (artifact bucket had no lifecycle policy) — 30-day
  expiration rule added.
- **CKV_AWS_300** (lifecycle missing incomplete-multipart-upload
  abort) — `abort_incomplete_multipart_upload` added to the same
  lifecycle rule.
- **CKV_AWS_314** (CodeBuild projects missing logging configuration)
  — `logs_config { cloudwatch_logs { status = "ENABLED" } }` added
  to all three CodeBuild projects.