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
    dynamodb   = "http://localhost:4566"
    iam        = "http://localhost:4566"
    logs       = "http://localhost:4566"
  }
}

# ── DynamoDB counter table ─────────────────────────────────────────────────

module "counter_table" {
  source   = "../../modules/dynamodb"
  name     = "load-balanced-counters"
  hash_key = "counter_id"
  tags     = local.tags
}

# ── ECS, ALB, Auto Scaling ────────────────────────────────────────────────
# NOTE: ECS, ALB, and Application Auto Scaling require LocalStack Pro.
#       The infrastructure below is scaffolded but commented out.
#
# In production this would include:
#   - aws_ecs_cluster + aws_ecs_task_definition (3 flask-api replicas)
#   - aws_lb + aws_lb_target_group + aws_lb_listener (ALB on port 8080)
#   - aws_appautoscaling_target + aws_appautoscaling_policy (2–10 replicas, 60% CPU)
#   - aws_iam_role for ECS task execution with DynamoDB read/write

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "load-balanced"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "counter_table_name" {
  value       = module.counter_table.table_name
  description = "DynamoDB table backing the /counter endpoint"
}

output "counter_table_arn" {
  value       = module.counter_table.table_arn
  description = "DynamoDB table ARN"
}
