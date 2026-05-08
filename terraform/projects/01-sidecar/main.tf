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

  endpoints {
    s3   = "http://localhost:4566"
    ecs  = "http://localhost:4566"
    iam  = "http://localhost:4566"
    logs = "http://localhost:4566"
  }
}

# ── S3 bucket for log shipping ─────────────────────────────────────────────

module "log_bucket" {
  source = "../../modules/s3"
  name   = "sidecar-logs"
  tags   = local.tags
}

# ── IAM role for ECS task ──────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_role" {
  name = "sidecar-ecs-task-role"

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

resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "sidecar-s3-write"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [
        module.log_bucket.bucket_arn,
        "${module.log_bucket.bucket_arn}/*"
      ]
    }]
  })
}

# ── ECS cluster ────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "sidecar-cluster"
  tags = local.tags
}

# ── CloudWatch log group ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/sidecar-flask-api"
  retention_in_days = 1
  tags              = local.tags
}

# ── ECS task definition ────────────────────────────────────────────────────
# Two containers:
#   1. flask-api  — the main application, logs to stdout as JSON
#   2. fluentbit  — the sidecar, reads from the shared volume and ships to S3

resource "aws_ecs_task_definition" "sidecar" {
  family                   = "sidecar-pattern"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  execution_role_arn       = aws_iam_role.ecs_task_role.arn

  # Shared volume between main container and sidecar
  volume {
    name = "app-logs"
  }

  container_definitions = jsonencode([
    {
      name      = "flask-api"
      image     = "flask-api:local"
      essential = true
      portMappings = [{
        containerPort = 5000
        protocol      = "tcp"
      }]
      environment = [
        { name = "LOG_LEVEL", value = "INFO" },
        { name = "LOG_DIR",   value = "/var/log/app" }
      ]
      # Mount shared volume — app writes JSON logs here
      mountPoints = [{
        sourceVolume  = "app-logs"
        containerPath = "/var/log/app"
        readOnly      = false
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = "eu-west-1"
          "awslogs-stream-prefix" = "flask-api"
        }
      }
    },
    {
      name      = "fluentbit-sidecar"
      image     = "amazon/aws-for-fluent-bit:latest"
      essential = false  # Task continues if sidecar crashes
      environment = [
        { name = "S3_BUCKET",   value = module.log_bucket.bucket_name },
        { name = "AWS_REGION",  value = "eu-west-1" },
        # Point Fluent Bit at LocalStack
        { name = "FLB_S3_ENDPOINT", value = "http://localhost:4566" }
      ]
      # Mount shared volume read-only — sidecar only reads logs
      mountPoints = [{
        sourceVolume  = "app-logs"
        containerPath = "/var/log/app"
        readOnly      = true
      }]
      dependsOn = [{
        containerName = "flask-api"
        condition     = "START"
      }]
    }
  ])

  tags = local.tags
}

# ── ECS service ────────────────────────────────────────────────────────────

resource "aws_ecs_service" "sidecar" {
  name            = "sidecar-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.sidecar.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = ["subnet-00000000"]  # LocalStack does not validate subnet IDs
    assign_public_ip = true
  }

  tags = local.tags
}

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "sidecar"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "log_bucket_name" {
  value       = module.log_bucket.bucket_name
  description = "S3 bucket receiving Fluent Bit log shipments"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "ECS cluster running the sidecar task"
}

output "task_definition_arn" {
  value       = aws_ecs_task_definition.sidecar.arn
  description = "ECS task definition ARN"
}
