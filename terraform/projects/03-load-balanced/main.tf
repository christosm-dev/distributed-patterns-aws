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
    dynamodb               = "http://localhost:4566"
    ecs                    = "http://localhost:4566"
    iam                    = "http://localhost:4566"
    logs                   = "http://localhost:4566"
    elasticloadbalancing   = "http://localhost:4566"
    ec2                    = "http://localhost:4566"
  }
}

# ── Build flask-api image ──────────────────────────────────────────────────

resource "null_resource" "build_flask_api" {
  triggers = {
    app        = filesha1("${path.module}/../../../docker/flask-api/app.py")
    dockerfile = filesha1("${path.module}/../../../docker/flask-api/Dockerfile")
    reqs       = filesha1("${path.module}/../../../docker/flask-api/requirements.txt")
  }

  provisioner "local-exec" {
    command = "docker build -t flask-api:local ${path.module}/../../../docker/flask-api"
  }
}

# ── DynamoDB counter table ─────────────────────────────────────────────────

module "counter_table" {
  source   = "../../modules/dynamodb"
  name     = "load-balanced-counters"
  hash_key = "counter_id"
  tags     = local.tags
}

# ── IAM role for ECS task ──────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_role" {
  name = "load-balanced-ecs-task-role"

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

resource "aws_iam_role_policy" "dynamodb" {
  name = "load-balanced-dynamodb"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem", "dynamodb:PutItem"]
      Resource = module.counter_table.table_arn
    }]
  })
}

# ── ECS cluster ────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "load-balanced-cluster"
  tags = local.tags
}

# ── ECS task definition ────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "flask_api" {
  family        = "load-balanced-flask-api"
  network_mode  = "bridge"
  task_role_arn = aws_iam_role.ecs_task_role.arn
  tags          = local.tags

  container_definitions = jsonencode([{
    name      = "flask-api"
    image     = "flask-api:local"
    essential = true
    portMappings = [{
      containerPort = 5000
      hostPort      = 8080
      protocol      = "tcp"
    }]
    environment = [
      { name = "DYNAMODB_TABLE",        value = module.counter_table.table_name },
      { name = "DYNAMODB_ENDPOINT_URL", value = "http://ministack:4566" },
      { name = "AWS_ACCESS_KEY_ID",     value = "test" },
      { name = "AWS_SECRET_ACCESS_KEY", value = "test" },
      { name = "AWS_DEFAULT_REGION",    value = "eu-west-1" },
    ]
  }])

  depends_on = [null_resource.build_flask_api]
}

# ── Application Load Balancer ──────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "load-balanced-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = ["subnet-00000001", "subnet-00000002"]
  tags               = local.tags
}

resource "aws_lb_target_group" "flask_api" {
  name        = "load-balanced-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = "vpc-00000001"
  target_type = "instance"

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.flask_api.arn
  }
}

# ── ECS service ────────────────────────────────────────────────────────────
# NOTE: aws_ecs_service panics on MiniStack bridge-mode responses.
# Created via CLI, same workaround as Project 01.

resource "null_resource" "ecs_service" {
  triggers = {
    cluster         = aws_ecs_cluster.main.id
    task_definition = aws_ecs_task_definition.flask_api.arn
    target_group    = aws_lb_target_group.flask_api.arn
  }

  provisioner "local-exec" {
    command = <<-EOF
      aws --endpoint-url=http://localhost:4566 ecs delete-service \
        --cluster ${aws_ecs_cluster.main.name} \
        --service load-balanced-service --force 2>/dev/null || true

      aws --endpoint-url=http://localhost:4566 ecs create-service \
        --cluster ${aws_ecs_cluster.main.name} \
        --service-name load-balanced-service \
        --task-definition ${aws_ecs_task_definition.flask_api.family} \
        --desired-count 1 \
        --load-balancers "targetGroupArn=${aws_lb_target_group.flask_api.arn},containerName=flask-api,containerPort=5000"
    EOF
  }

  depends_on = [aws_lb_listener.http]
}

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

output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "ALB DNS name — hit port 8080 for the flask-api"
}

output "alb_endpoint" {
  value       = "http://localhost:8080"
  description = "Local endpoint via ALB listener"
}
