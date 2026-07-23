terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region  = "us-east-1"
  profile = "pietrocorp-cicd-pipeline"
}

variable "pipeline_name" {
  description = "Placeholder until the pipeline module is built"
  type        = string
  default     = "cicd-pipeline-placeholder"
}

resource "aws_secretsmanager_secret" "github_webhook" {
  # checkov:skip=CKV_AWS_149: AWS-managed key sufficient; see docs/security/scan-exceptions.md
  # checkov:skip=CKV2_AWS_57: automatic rotation deferred, documented follow-up; see ADR 001
  name = "cicd-pipeline/github-webhook-secret"
}

module "webhook_receiver" {
  source = "../../modules/webhook-receiver"

  project_name       = "cicd-pipeline"
  pipeline_name      = module.pipeline.pipeline_name
  webhook_secret_arn = aws_secretsmanager_secret.github_webhook.arn
}

output "webhook_url" {
  value = module.webhook_receiver.webhook_url
}

variable "webhook_secret_value" {
  description = "The GitHub webhook HMAC secret - passed via TF_VAR or a gitignored .tfvars file, never committed"
  type        = string
  sensitive   = true
}

resource "aws_secretsmanager_secret_version" "github" {
  secret_id     = aws_secretsmanager_secret.github_webhook.id
  secret_string = var.webhook_secret_value
}

module "pipeline" {
  source             = "../../modules/pipeline"
  webhook_secret_arn = aws_secretsmanager_secret.github_webhook.arn
}

module "approval_gate" {
  source             = "../../modules/approval-gate"
  notification_email = var.approval_notification_email
}

variable "approval_notification_email" {
  description = "Email to notify for pipeline manual approvals"
  type        = string
}