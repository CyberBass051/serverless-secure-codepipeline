data "archive_file" "handler" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/webhook_handler"
  output_path = "${path.module}/handler.zip"
}

resource "aws_iam_role" "lambda_exec" {
  name = "cicd-pipeline-webhook-handler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "cicd-pipeline-webhook-handler-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SecretsRead"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.webhook_secret_arn
      },
      {
        Sid      = "TriggerPipeline"
        Effect   = "Allow"
        Action   = "codepipeline:StartPipelineExecution"
        Resource = "arn:aws:codepipeline:us-east-1:221717898536:${var.pipeline_name}"
      },
      {
        Sid      = "Logging"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:221717898536:log-group:/aws/lambda/cicd-pipeline-*"
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        Sid      = "DLQSend"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.webhook_dlq.arn
      }
    ]
  })
}

resource "aws_lambda_function" "webhook_handler" {
  # checkov:skip=CKV_AWS_173: env vars are non-sensitive identifiers, not secrets; see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_272: single-maintainer project, code signing overhead not justified; see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_117: public webhook receiver, VPC placement adds cost with no security benefit; see docs/security/scan-exceptions.md
  function_name    = "cicd-pipeline-webhook-handler"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 10

  dead_letter_config {
    target_arn = aws_sqs_queue.webhook_dlq.arn
  }
  reserved_concurrent_executions = -1
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      WEBHOOK_SECRET_ARN = var.webhook_secret_arn
      PIPELINE_NAME      = var.pipeline_name
    }
  }
}

resource "aws_apigatewayv2_api" "webhook" {
  name          = "cicd-pipeline-webhook"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.webhook_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webhook_post" {
  # checkov:skip=CKV_AWS_309: GitHub webhooks cannot use IAM/JWT auth;
  # authentication is enforced via HMAC signature verification in the Lambda handler.
  api_id    = aws_apigatewayv2_api.webhook.id
  route_key = "POST /webhook"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.webhook.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId = "$context.requestId", ip = "$context.identity.sourceIp",
      requestTime = "$context.requestTime", routeKey = "$context.routeKey",
      status = "$context.status", integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}

output "webhook_url" {
  description = "The invoke URL for the GitHub webhook"
  value = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/webhook"
}

resource "aws_sqs_queue" "webhook_dlq" {
  # checkov:skip=CKV_AWS_27: SSE-SQS (AWS-owned key) is sufficient —
  # this queue holds only failed webhook invocation metadata, not
  # secrets; see docs/security/scan-exceptions.md
  name                    = "cicd-pipeline-webhook-dlq"
  sqs_managed_sse_enabled = true
}

resource "aws_cloudwatch_log_group" "api_gw" {
  # checkov:skip=CKV_AWS_158: AWS-managed key sufficient for access-log
  # metadata (no sensitive content); see docs/security/scan-exceptions.md
  name              = "/aws/apigateway/cicd-pipeline-webhook"
  retention_in_days = 365
}

