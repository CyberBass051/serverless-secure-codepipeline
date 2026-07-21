variable "project_name" {
  description = "Project name prefix used for resource naming"
  type        = string
}

variable "pipeline_name" {
  description = "Name of the CodePipeline this Lambda triggers"
  type        = string
}

variable "webhook_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the GitHub webhook HMAC secret"
  type        = string
}