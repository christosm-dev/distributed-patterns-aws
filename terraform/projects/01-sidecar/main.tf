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
# NOTE: ECS requires LocalStack Pro — commented out for community edition

# resource "aws_ecs_cluster" "main" {
#   name = "sidecar-cluster"
#   tags = local.tags
# }

# ── CloudWatch log group ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/sidecar-flask-api"
  retention_in_days = 1
  tags              = local.tags
}

# ── ECS task definition + service ─────────────────────────────────────────
# NOTE: ECS requires LocalStack Pro — commented out for community edition

# resource "aws_ecs_task_definition" "sidecar" { ... }
# resource "aws_ecs_service" "sidecar" { ... }

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

# output "ecs_cluster_name" { ... }    # requires LocalStack Pro
# output "task_definition_arn" { ... } # requires LocalStack Pro
