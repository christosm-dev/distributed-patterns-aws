terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    sqs        = "http://localhost:4566"
    lambda     = "http://localhost:4566"
    iam        = "http://localhost:4566"
    ssm        = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
    logs       = "http://localhost:4566"
  }
}

# ── SQS queue + DLQ ────────────────────────────────────────────────────────

module "queue" {
  source            = "../../modules/sqs"
  name              = "ambassador-queue"
  max_receive_count = 3
  tags              = local.tags
}

# ── SSM parameter — queue URL ──────────────────────────────────────────────

resource "aws_ssm_parameter" "queue_url" {
  name  = "/ambassador/queue-url"
  type  = "String"
  value = module.queue.queue_url
  tags  = local.tags
}

# ── IAM roles ──────────────────────────────────────────────────────────────

module "ambassador_role" {
  source = "../../modules/iam"
  name   = "ambassador-role"
  tags   = local.tags

  inline_policies = {
    sqs-send = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = module.queue.queue_arn
      }]
    })
    ssm-read = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.queue_url.arn
      }]
    })
  }
}

module "producer_role" {
  source = "../../modules/iam"
  name   = "ambassador-producer-role"
  tags   = local.tags

  inline_policies = {
    invoke-ambassador = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = module.ambassador_lambda.function_arn
      }]
    })
  }
}

module "consumer_role" {
  source = "../../modules/iam"
  name   = "ambassador-consumer-role"
  tags   = local.tags

  inline_policies = {
    sqs-consume = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
        ]
        Resource = module.queue.queue_arn
      }]
    })
  }
}

# ── Lambda functions ───────────────────────────────────────────────────────

module "ambassador_lambda" {
  source     = "../../modules/lambda"
  name       = "ambassador"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/ambassador"
  role_arn   = module.ambassador_role.role_arn
  tags       = local.tags

  environment_variables = {
    QUEUE_URL_PARAM  = aws_ssm_parameter.queue_url.name
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

module "producer_lambda" {
  source     = "../../modules/lambda"
  name       = "producer"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/producer"
  role_arn   = module.producer_role.role_arn
  tags       = local.tags

  environment_variables = {
    AMBASSADOR_FUNCTION = module.ambassador_lambda.function_name
    AWS_ENDPOINT_URL    = "http://ministack:4566"
  }
}

module "consumer_lambda" {
  source     = "../../modules/lambda"
  name       = "consumer"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/consumer"
  role_arn   = module.consumer_role.role_arn
  tags       = local.tags

  environment_variables = {
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

# ── SQS → Consumer event source mapping ───────────────────────────────────

resource "aws_lambda_event_source_mapping" "sqs_consumer" {
  event_source_arn = module.queue.queue_arn
  function_name    = module.consumer_lambda.function_arn
  batch_size       = 10
  enabled          = true
}

# ── CloudWatch alarm — DLQ depth ──────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "ambassador-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "DLQ has messages — consumer is failing"

  dimensions = {
    QueueName = module.queue.dlq_name
  }

  tags = local.tags
}

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "ambassador"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "producer_function_name" {
  value = module.producer_lambda.function_name
}

output "ambassador_function_name" {
  value = module.ambassador_lambda.function_name
}

output "queue_url" {
  value = module.queue.queue_url
}

output "dlq_url" {
  value = module.queue.dlq_url
}
