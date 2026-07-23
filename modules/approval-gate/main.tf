resource "aws_sns_topic" "approval" {
  name              = "cicd-pipeline-approval-notifications"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_policy" "approval" {
  arn = aws_sns_topic.approval.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCodePipelinePublish"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.approval.arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = "221717898536"
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.approval.arn
  protocol  = "email"
  endpoint   = var.notification_email
}