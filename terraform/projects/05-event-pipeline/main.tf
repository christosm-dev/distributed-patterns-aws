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
    apigateway = "http://localhost:4566"
    sns        = "http://localhost:4566"
    sqs        = "http://localhost:4566"
    lambda     = "http://localhost:4566"
    iam        = "http://localhost:4566"
    dynamodb   = "http://localhost:4566"
    s3         = "http://localhost:4566"
    logs       = "http://localhost:4566"
  }
}

# ── DynamoDB items table ───────────────────────────────────────────────────

module "items_table" {
  source        = "../../modules/dynamodb"
  name          = "pipeline-items"
  hash_key      = "id"
  ttl_attribute = "expires_at"
  tags          = local.tags

  global_secondary_indexes = [{
    name            = "score-index"
    hash_key        = "score"
    hash_key_type   = "N"
    range_key       = null
    range_key_type  = null
    projection_type = "ALL"
  }]
}

# ── S3 notifications bucket ────────────────────────────────────────────────

module "results_bucket" {
  source = "../../modules/s3"
  name   = "pipeline-notifications"
  tags   = local.tags
}

# ── SNS topic ──────────────────────────────────────────────────────────────

resource "aws_sns_topic" "pipeline" {
  name = "event-pipeline"
  tags = local.tags
}

# ── SQS queues ────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "processing" {
  name                      = "pipeline-processing"
  message_retention_seconds = 86400
  tags                      = local.tags
}

resource "aws_sqs_queue" "notification" {
  name                      = "pipeline-notification"
  message_retention_seconds = 86400
  tags                      = local.tags
}

# Allow SNS to send to both queues

resource "aws_sqs_queue_policy" "processing" {
  queue_url = aws_sqs_queue.processing.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.processing.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.pipeline.arn } }
    }]
  })
}

resource "aws_sqs_queue_policy" "notification" {
  queue_url = aws_sqs_queue.notification.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.notification.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.pipeline.arn } }
    }]
  })
}

# ── SNS → SQS subscriptions ────────────────────────────────────────────────

resource "aws_sns_topic_subscription" "to_processing" {
  topic_arn = aws_sns_topic.pipeline.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.processing.arn
}

resource "aws_sns_topic_subscription" "to_notification" {
  topic_arn = aws_sns_topic.pipeline.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notification.arn
}

# ── IAM roles ──────────────────────────────────────────────────────────────

module "ingest_role" {
  source = "../../modules/iam"
  name   = "pipeline-ingest-role"
  tags   = local.tags

  inline_policies = {
    sns-publish = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.pipeline.arn
      }]
    })
  }
}

module "process_role" {
  source = "../../modules/iam"
  name   = "pipeline-process-role"
  tags   = local.tags

  inline_policies = {
    sqs-consume = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.processing.arn
      }]
    })
    dynamodb-write = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.items_table.table_arn
      }]
    })
  }
}

module "notify_role" {
  source = "../../modules/iam"
  name   = "pipeline-notify-role"
  tags   = local.tags

  inline_policies = {
    sqs-consume = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.notification.arn
      }]
    })
    s3-write = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${module.results_bucket.bucket_arn}/*"
      }]
    })
  }
}

# ── Lambda functions ───────────────────────────────────────────────────────

module "ingest_lambda" {
  source     = "../../modules/lambda"
  name       = "pipeline-ingest"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/ingest"
  role_arn   = module.ingest_role.role_arn
  tags       = local.tags

  environment_variables = {
    TOPIC_ARN        = aws_sns_topic.pipeline.arn
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

module "process_lambda" {
  source     = "../../modules/lambda"
  name       = "pipeline-process"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/process"
  role_arn   = module.process_role.role_arn
  tags       = local.tags

  environment_variables = {
    TABLE_NAME       = module.items_table.table_name
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

module "notify_lambda" {
  source     = "../../modules/lambda"
  name       = "pipeline-notify"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/notify"
  role_arn   = module.notify_role.role_arn
  tags       = local.tags

  environment_variables = {
    S3_BUCKET        = module.results_bucket.bucket_name
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

# ── SQS → Lambda event source mappings ────────────────────────────────────

resource "aws_lambda_event_source_mapping" "process" {
  event_source_arn = aws_sqs_queue.processing.arn
  function_name    = module.process_lambda.function_arn
  batch_size       = 10
}

resource "aws_lambda_event_source_mapping" "notify" {
  event_source_arn = aws_sqs_queue.notification.arn
  function_name    = module.notify_lambda.function_arn
  batch_size       = 10
}

# ── API Gateway ────────────────────────────────────────────────────────────

resource "aws_api_gateway_rest_api" "pipeline" {
  name = "event-pipeline"
  tags = local.tags
}

resource "aws_api_gateway_resource" "ingest" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  parent_id   = aws_api_gateway_rest_api.pipeline.root_resource_id
  path_part   = "ingest"
}

resource "aws_api_gateway_method" "post_ingest" {
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  resource_id   = aws_api_gateway_resource.ingest.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "ingest_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.pipeline.id
  resource_id             = aws_api_gateway_resource.ingest.id
  http_method             = aws_api_gateway_method.post_ingest.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = module.ingest_lambda.invoke_arn
}

resource "aws_api_gateway_deployment" "pipeline" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  depends_on  = [aws_api_gateway_integration.ingest_lambda]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  deployment_id = aws_api_gateway_deployment.pipeline.id
  stage_name    = "prod"
}

resource "aws_lambda_permission" "apigw_ingest" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.ingest_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.pipeline.execution_arn}/*/*"
}

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "event-pipeline"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "api_endpoint" {
  value = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.pipeline.id}/prod/_user_request_/ingest"
}

output "items_table_name" {
  value = module.items_table.table_name
}

output "results_bucket" {
  value = module.results_bucket.bucket_name
}

output "topic_arn" {
  value = aws_sns_topic.pipeline.arn
}
