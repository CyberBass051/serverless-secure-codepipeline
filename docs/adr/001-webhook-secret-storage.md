# ADR 001: GitHub Webhook Secret Storage

## Status
Accepted

## Context
The webhook Lambda needs to verify the HMAC-SHA256 signature GitHub sends
with every webhook delivery (`X-Hub-Signature-256`), which requires the
Lambda to read the shared secret at invocation time.

Two options were initially considered:
- **GitHub Secrets** (repo Settings → Secrets and variables → Actions)
- **AWS Secrets Manager**

## Decision
AWS Secrets Manager.

GitHub Secrets are only ever injected as environment variables into
GitHub Actions workflow runs. They are not retrievable via any API
outside that context, so a Lambda function cannot read them at
runtime — this option was eliminated on technical grounds, not
preference.

Between AWS Secrets Manager and SSM Parameter Store (SecureString),
Secrets Manager was chosen for:
- Native automatic rotation support (not configured yet, documented
  as a follow-up — see Consequences)
- Being the AWS-idiomatic, exam/job-posting-standard tool for secret
  management in cloud security roles, over Parameter Store
- Native CloudTrail audit trail on secret access

## Consequences
- Adds a small recurring cost (~$0.40/secret/month) versus the free
  SSM alternative — accepted as negligible at this scale.
- Automatic rotation is supported but not yet implemented. Manual
  rotation only, for now.
- Lambda's execution role is scoped to `secretsmanager:GetSecretValue`
  on this single secret's ARN, not a wildcard.