# ── Packaging (initial creation only — CodeBuild handles all updates after) ──
data "archive_file" "prod_handler" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/webhook_handler"
  output_path = "${path.module}/prod_handler.zip"
}

# ── Source: GitHub via CodeStar Connections ──
# NOTE: requires a one-time manual authorization in the AWS Console after apply
# (Console → Developer Tools → Settings → Connections → complete "Update pending connection")
resource "aws_codestarconnections_connection" "github" {
  name          = "cicd-pipeline-github"
  provider_type = "GitHub"
}

# ── Artifact storage ──
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket" "pipeline_artifacts" {
  # checkov:skip=CKV_AWS_145: AWS-managed key sufficient for build artifacts (source code zips, not secrets); see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_18: access logging overhead not justified for a build-artifact-only bucket; see docs/security/scan-exceptions.md
  # checkov:skip=CKV2_AWS_62: no event-driven use case for this bucket; see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_144: single-region demo project, cross-region replication not justified; see docs/security/scan-exceptions.md
  bucket = "cicd-pipeline-artifacts-221717898536"
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── Prod Lambda (demonstration promotion target — not wired to API Gateway) ──
resource "aws_iam_role" "lambda_exec_prod" {
  name = "cicd-pipeline-webhook-handler-prod-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_exec_prod" {
  name = "cicd-pipeline-webhook-handler-prod-policy"
  role = aws_iam_role.lambda_exec_prod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logging"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:221717898536:log-group:/aws/lambda/cicd-pipeline-*"
      },
      {
        Sid      = "DLQSend"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.prod_dlq.arn
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sqs_queue" "prod_dlq" {
  # checkov:skip=CKV_AWS_27: AWS-managed key sufficient; see docs/security/scan-exceptions.md
  name                    = "cicd-pipeline-webhook-prod-dlq"
  sqs_managed_sse_enabled = true
}


resource "aws_lambda_function" "webhook_handler_prod" {
  # checkov:skip=CKV_AWS_117: demo/promotion-target Lambda, not in VPC; see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_173: env vars are non-sensitive identifiers, not secrets; see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_272: single-maintainer project, code signing overhead not justified; see docs/security/scan-exceptions.md
  # checkov:skip=CKV_AWS_115: account-level concurrency quota (10 total, AWS enforces a 10-unreserved floor) makes any reservation infeasible without a quota increase; see docs/security/scan-exceptions.md
  function_name    = "cicd-pipeline-webhook-handler-prod"
  role             = aws_iam_role.lambda_exec_prod.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.prod_handler.output_path
  source_code_hash = data.archive_file.prod_handler.output_base64sha256
  timeout          = 10


  dead_letter_config {
    target_arn = aws_sqs_queue.prod_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      WEBHOOK_SECRET_ARN = var.webhook_secret_arn
      PIPELINE_NAME      = "cicd-pipeline-placeholder"
    }
  }
}

# ── Build stage ──
resource "aws_iam_role" "codebuild_build" {
  name = "cicd-pipeline-codebuild-build"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_build" {
  name = "cicd-pipeline-codebuild-build-policy"
  role = aws_iam_role.codebuild_build.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ArtifactBucketAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
      {
        Sid      = "Logging"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:221717898536:log-group:/aws/codebuild/cicd-pipeline-*"
      }
    ]
  })
}

resource "aws_codebuild_project" "build" {
  # checkov:skip=CKV_AWS_147: build logs/artifacts, not secrets; AWS-managed key sufficient; see docs/security/scan-exceptions.md
  name         = "cicd-pipeline-build"
  service_role = aws_iam_role.codebuild_build.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-build.yml"
  }
}

# ── Deploy stages (dev + prod) ──
resource "aws_iam_role" "codebuild_deploy" {
  name = "cicd-pipeline-codebuild-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_deploy" {
  name = "cicd-pipeline-codebuild-deploy-policy"
  role = aws_iam_role.codebuild_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaCodeUpdate"
        Effect = "Allow"
        Action = ["lambda:UpdateFunctionCode", "lambda:GetFunction"]
        Resource = [
          "arn:aws:lambda:us-east-1:221717898536:function:cicd-pipeline-webhook-handler",
          aws_lambda_function.webhook_handler_prod.arn
        ]
      },
      {
        Sid      = "ArtifactBucketAccess"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
      {
        Sid      = "Logging"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:221717898536:log-group:/aws/codebuild/cicd-pipeline-*"
      }
    ]
  })
}

resource "aws_codebuild_project" "deploy_dev" {
  # checkov:skip=CKV_AWS_147: build logs/artifacts, not secrets; AWS-managed key sufficient; see docs/security/scan-exceptions.md
  name         = "cicd-pipeline-deploy-dev"
  service_role = aws_iam_role.codebuild_deploy.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy-dev.yml"
  }
}

resource "aws_codebuild_project" "deploy_prod" {
  # checkov:skip=CKV_AWS_147: build logs/artifacts, not secrets; AWS-managed key sufficient; see docs/security/scan-exceptions.md
  name         = "cicd-pipeline-deploy-prod"
  service_role = aws_iam_role.codebuild_deploy.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy-prod.yml"
  }
}

# ── CodePipeline service role ──
resource "aws_iam_role" "codepipeline" {
  name = "cicd-pipeline-codepipeline-service"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "cicd-pipeline-codepipeline-service-policy"
  role = aws_iam_role.codepipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactBucketAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Sid      = "CodeStarConnectionUse"
        Effect   = "Allow"
        Action   = "codestar-connections:UseConnection"
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Sid    = "CodeBuildTrigger"
        Effect = "Allow"
        Action = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [
          aws_codebuild_project.build.arn,
          aws_codebuild_project.deploy_dev.arn,
          aws_codebuild_project.deploy_prod.arn
        ]
      }
    ]
  })
}

# ── The pipeline itself ──
resource "aws_codepipeline" "this" {
  # checkov:skip=CKV_AWS_219: artifact store holds build artifacts (source zips), not secrets; AWS-managed key sufficient; see docs/security/scan-exceptions.md
  name     = "cicd-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = "CyberBass051/serverless-secure-codepipeline"
        BranchName       = "main"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "DeployDev"
    action {
      name            = "DeployDev"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.deploy_dev.name
      }
    }
  }

  stage {
    name = "ApprovalGate"
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        NotificationArn = module.approval_gate.topic_arn
        CustomData      = "Review the build and approve to promote to prod."
      }
    }
  }

  stage {
    name = "DeployProd"
    action {
      name            = "DeployProd"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.deploy_prod.name
      }
    }
  }
}
