variable "webhook_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the GitHub webhook HMAC secret"
  type        = string
}