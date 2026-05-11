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
    s3         = "http://localhost:4566"
    ecs        = "http://localhost:4566"
    iam        = "http://localhost:4566"
    logs       = "http://localhost:4566"
  }
}

# ── Build Docker images ────────────────────────────────────────────────────

resource "null_resource" "build_images" {
  triggers = {
    flask_app        = filesha1("${path.module}/../../../docker/flask-api/app.py")
    flask_dockerfile = filesha1("${path.module}/../../../docker/flask-api/Dockerfile")
    flask_reqs       = filesha1("${path.module}/../../../docker/flask-api/requirements.txt")
    shipper          = filesha1("${path.module}/../../../docker/log-shipper/log_shipper.py")
    shipper_docker   = filesha1("${path.module}/../../../docker/log-shipper/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<-EOF
      docker build -t flask-api:local ${path.module}/../../../docker/flask-api
      docker build -t log-shipper:local ${path.module}/../../../docker/log-shipper
    EOF
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

# ── CloudWatch log group ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/sidecar-flask-api"
  retention_in_days = 1
  tags              = local.tags
}

# ── ECS cluster ────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "sidecar-cluster"
  tags = local.tags
}

# ── ECS task definition ────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "sidecar" {
  family       = "sidecar-flask-api"
  network_mode = "bridge"
  tags         = local.tags

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
        hostPort      = 5000
        protocol      = "tcp"
      }]
      environment = [
        { name = "LOG_DIR",               value = "/var/log/app" },
        { name = "LOG_LEVEL",             value = "INFO" },
        { name = "DYNAMODB_TABLE",        value = "load-balanced-counters" },
        { name = "DYNAMODB_ENDPOINT_URL", value = "http://ministack:4566" },
        { name = "AWS_ACCESS_KEY_ID",     value = "test" },
        { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
        { name = "AWS_DEFAULT_REGION",    value = "eu-west-1" },
      ]
      mountPoints = [{
        sourceVolume  = "app-logs"
        containerPath = "/var/log/app"
        readOnly      = false
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"  = aws_cloudwatch_log_group.app.name
          "awslogs-region" = "eu-west-1"
        }
      }
    },
    {
      name      = "log-shipper"
      image     = "log-shipper:local"
      essential = false
      environment = [
        { name = "S3_BUCKET",            value = module.log_bucket.bucket_name },
        { name = "S3_ENDPOINT_URL",      value = "http://ministack:4566" },
        { name = "AWS_ACCESS_KEY_ID",    value = "test" },
        { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
        { name = "AWS_REGION",           value = "eu-west-1" },
        { name = "FLUSH_INTERVAL",       value = "30" },
      ]
      mountPoints = [{
        sourceVolume  = "app-logs"
        containerPath = "/var/log/app"
        readOnly      = true
      }]
    }
  ])

  depends_on = [null_resource.build_images]
}

# ── ECS service ────────────────────────────────────────────────────────────
# NOTE: The Terraform AWS provider panics reading back the ECS service response
# from MiniStack (nil networkConfiguration in bridge mode). Created via CLI
# instead, matching the null_resource workaround used for Step Functions.

resource "null_resource" "ecs_service" {
  triggers = {
    cluster         = aws_ecs_cluster.main.id
    task_definition = aws_ecs_task_definition.sidecar.arn
  }

  provisioner "local-exec" {
    command = <<-EOF
      aws --endpoint-url=http://localhost:4566 ecs delete-service \
        --cluster ${aws_ecs_cluster.main.name} \
        --service sidecar-service --force 2>/dev/null || true

      aws --endpoint-url=http://localhost:4566 ecs create-service \
        --cluster ${aws_ecs_cluster.main.name} \
        --service-name sidecar-service \
        --task-definition ${aws_ecs_task_definition.sidecar.family} \
        --desired-count 1
    EOF
  }
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
  description = "S3 bucket receiving log shipments"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "ECS cluster running the sidecar task"
}

output "task_definition_arn" {
  value       = aws_ecs_task_definition.sidecar.arn
  description = "ECS task definition ARN (service managed via null_resource)"
}
