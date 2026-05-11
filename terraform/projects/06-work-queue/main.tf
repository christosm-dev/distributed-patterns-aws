terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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
    dynamodb   = "http://localhost:4566"
    ecs        = "http://localhost:4566"
    logs       = "http://localhost:4566"
    cloudwatch = "http://localhost:4566"
  }
}

# ── SQS work queue ─────────────────────────────────────────────────────────

module "work_queue" {
  source                     = "../../modules/sqs"
  name                       = "work-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  max_receive_count          = 3
  tags                       = local.tags
}

# ── DynamoDB results table ──────────────────────────────────────────────────

module "results_table" {
  source   = "../../modules/dynamodb"
  name     = "work-queue-results"
  hash_key = "id"
  tags     = local.tags

  global_secondary_indexes = [{
    name            = "worker-index"
    hash_key        = "worker_id"
    hash_key_type   = "S"
    range_key       = null
    range_key_type  = null
    projection_type = "ALL"
  }]
}

# ── IAM roles ──────────────────────────────────────────────────────────────

module "worker_role" {
  source = "../../modules/iam"
  name   = "work-queue-worker-role"
  tags   = local.tags

  inline_policies = {
    sqs-consume = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = module.work_queue.queue_arn
      }]
    })
    lambda-invoke = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "*"
      }]
    })
  }
}

module "adapter_role" {
  source = "../../modules/iam"
  name   = "work-queue-adapter-role"
  tags   = local.tags

  inline_policies = {
    dynamodb-write = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = module.results_table.table_arn
      }]
    })
    cloudwatch-metrics = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }]
    })
  }
}

# ── Adapter Lambda ─────────────────────────────────────────────────────────

module "adapter_lambda" {
  source     = "../../modules/lambda"
  name       = "work-queue-adapter"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/adapter"
  role_arn   = module.adapter_role.role_arn
  tags       = local.tags

  environment_variables = {
    TABLE_NAME       = module.results_table.table_name
    METRIC_NAMESPACE = "WorkQueue"
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

# ── Worker Lambdas ─────────────────────────────────────────────────────────

module "worker_1" {
  source     = "../../modules/lambda"
  name       = "work-queue-worker-1"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/worker"
  role_arn   = module.worker_role.role_arn
  tags       = local.tags

  environment_variables = {
    WORKER_ID        = "1"
    ADAPTER_FUNCTION = module.adapter_lambda.function_name
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

module "worker_2" {
  source     = "../../modules/lambda"
  name       = "work-queue-worker-2"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/worker"
  role_arn   = module.worker_role.role_arn
  tags       = local.tags

  environment_variables = {
    WORKER_ID        = "2"
    ADAPTER_FUNCTION = module.adapter_lambda.function_name
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

module "worker_3" {
  source     = "../../modules/lambda"
  name       = "work-queue-worker-3"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/worker"
  role_arn   = module.worker_role.role_arn
  tags       = local.tags

  environment_variables = {
    WORKER_ID        = "3"
    ADAPTER_FUNCTION = module.adapter_lambda.function_name
    AWS_ENDPOINT_URL = "http://ministack:4566"
  }
}

# ── SQS → Lambda event source mappings ────────────────────────────────────

resource "aws_lambda_event_source_mapping" "worker_1" {
  event_source_arn = module.work_queue.queue_arn
  function_name    = module.worker_1.function_arn
  batch_size       = 10
}

resource "aws_lambda_event_source_mapping" "worker_2" {
  event_source_arn = module.work_queue.queue_arn
  function_name    = module.worker_2.function_arn
  batch_size       = 10
}

resource "aws_lambda_event_source_mapping" "worker_3" {
  event_source_arn = module.work_queue.queue_arn
  function_name    = module.worker_3.function_arn
  batch_size       = 10
}

# ── Build producer Docker image ────────────────────────────────────────────

resource "null_resource" "build_producer_image" {
  triggers = {
    producer    = filesha1("${path.module}/../../../docker/log-producer/log_producer.py")
    dockerfile  = filesha1("${path.module}/../../../docker/log-producer/Dockerfile")
    reqs        = filesha1("${path.module}/../../../docker/log-producer/requirements.txt")
  }

  provisioner "local-exec" {
    command = "docker build -t log-producer:local ${path.module}/../../../docker/log-producer"
  }
}

# ── ECS cluster for producer ───────────────────────────────────────────────

resource "aws_iam_role" "producer_task_role" {
  name = "work-queue-producer-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "producer_sqs" {
  name = "work-queue-producer-sqs"
  role = aws_iam_role.producer_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:SendMessageBatch", "sqs:GetQueueUrl"]
      Resource = module.work_queue.queue_arn
    }]
  })
}

resource "aws_ecs_cluster" "producer" {
  name = "work-queue-producer-cluster"
  tags = local.tags
}

resource "aws_ecs_task_definition" "producer" {
  family       = "work-queue-producer"
  network_mode = "bridge"
  task_role_arn = aws_iam_role.producer_task_role.arn
  tags         = local.tags

  container_definitions = jsonencode([{
    name      = "log-producer"
    image     = "log-producer:local"
    essential = true
    environment = [
      { name = "QUEUE_URL",            value = module.work_queue.queue_url },
      { name = "TOTAL_ITEMS",          value = "30" },
      { name = "AWS_ENDPOINT_URL",     value = "http://ministack:4566" },
      { name = "AWS_ACCESS_KEY_ID",    value = "test" },
      { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
      { name = "AWS_DEFAULT_REGION",   value = "eu-west-1" },
    ]
  }])

  depends_on = [null_resource.build_producer_image]
}

# ── Run the producer as a one-shot ECS task ────────────────────────────────
# NOTE: aws_ecs_service panics on MiniStack bridge-mode responses.
# Run the producer via CLI once infrastructure is ready.

resource "null_resource" "run_producer" {
  triggers = {
    task_definition = aws_ecs_task_definition.producer.arn
  }

  provisioner "local-exec" {
    command = <<-EOF
      aws --endpoint-url=http://localhost:4566 ecs run-task \
        --cluster ${aws_ecs_cluster.producer.name} \
        --task-definition ${aws_ecs_task_definition.producer.family} \
        --count 1
    EOF
  }

  depends_on = [
    aws_ecs_task_definition.producer,
    aws_lambda_event_source_mapping.worker_1,
    aws_lambda_event_source_mapping.worker_2,
    aws_lambda_event_source_mapping.worker_3,
  ]
}

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "work-queue"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "queue_url" {
  value = module.work_queue.queue_url
}

output "queue_dlq_url" {
  value = module.work_queue.dlq_url
}

output "results_table_name" {
  value = module.results_table.table_name
}

output "adapter_function_name" {
  value = module.adapter_lambda.function_name
}
