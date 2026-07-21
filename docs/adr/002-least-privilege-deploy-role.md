# ADR 002: Least-Privilege IAM Identity Center Permission Set for Deployment

## Status
Accepted

## Context
Terraform for this project was initially going to be applied using the
existing `pietrocorp-management` (AdministratorAccess) SSO profile, the
same one used to bootstrap the shared Terraform backend. Continuing to
deploy every project as admin defeats the purpose of practicing
least-privilege access management, and was already identified as an
anti-pattern earlier in the `pietrocorp` environment.

## Decision
A dedicated IAM Identity Center permission set, `CICDPipeline`,
was created and assigned for this project instead of reusing the admin
profile. The policy scopes access by resource-name prefix
(`cicd-pipeline-*`) across Lambda, CodePipeline, CodeBuild, Secrets
Manager, and IAM role management, plus explicit read/write access to
this project's slice of the shared Terraform state backend
(`cicd-pipeline/*` key prefix in the shared S3 bucket, and the shared
DynamoDB lock table).

### iam:PassRole handling
`iam:PassRole` was isolated into its own statement (separate from
`iam:CreateRole`/`AttachRolePolicy`/`PutRolePolicy`), scoped to
`role/cicd-pipeline-*`, with an `iam:PassedToService` condition
restricting it to `lambda.amazonaws.com`, `codepipeline.amazonaws.com`,
and `codebuild.amazonaws.com`. This was a fix applied after an initial
draft incorrectly combined `PassRole` and role-creation actions under
one condition — `iam:PassedToService` is not a valid condition key for
`CreateRole`/`AttachRolePolicy`/`PutRolePolicy`, and combining them
would have silently denied those actions despite the policy appearing
to grant them.

A Checkov finding (`PassRole With Star In Resource`) caught an earlier
draft's use of `Resource: "*"` on `iam:PassRole` before this policy was
ever applied, prompting the scoped-resource + condition-key design.

## Consequences
- `events:*`, `sns:*`, and `logs:*` remain scoped to `Resource: "*"`
  (accepted exception) — EventBridge/SNS resource ARNs don't share a
  clean project-prefix convention the way Lambda/CodePipeline/IAM do,
  and CloudWatch Logs group names aren't known until resources are
  created. Revisit if this project's scope grows enough to justify
  tighter scoping.
- Any future AWS service this project needs will require a policy
  update — deploys will fail with `AccessDenied` rather than silently
  succeeding with broader-than-needed access, by design.
- This permission set is specific to this project; other `pietrocorp`
  projects get their own permission sets rather than a shared one.