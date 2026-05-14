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
    lambda     = "http://localhost:4566"
    iam        = "http://localhost:4566"
    apigateway = "http://localhost:4566"
    logs       = "http://localhost:4566"
  }
}

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "circuit-breaker"
  }
}

# ── IAM role shared by both Lambda functions ───────────────────────────────────

module "lambda_role" {
  source = "../../modules/iam"
  name   = "circuit-breaker-lambda-role"
  tags   = local.tags
}

# ── Downstream Lambda (flaky service) ─────────────────────────────────────────

module "downstream_function" {
  source      = "../../modules/lambda"
  name        = "downstream-service"
  handler     = "handler.handler"
  source_dir  = "${path.module}/../../../sam/07-circuit-breaker/downstream"
  role_arn    = module.lambda_role.role_arn
  timeout     = 10
  environment_variables = {
    FAILURE_RATE = "0.0"
  }
  tags = local.tags
}

# ── API Lambda (circuit breaker wrapping downstream) ──────────────────────────

module "api_function" {
  source      = "../../modules/lambda"
  name        = "api-service"
  handler     = "handler.handler"
  source_dir  = "${path.module}/../../../sam/07-circuit-breaker/api"
  role_arn    = module.lambda_role.role_arn
  timeout     = 10
  environment_variables = {
    DOWNSTREAM_URL = "http://localhost:4566/restapis/.../prod/users"
  }
  tags = local.tags
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "downstream_function_name" {
  value = module.downstream_function.function_name
}

output "api_function_name" {
  value = module.api_function.function_name
}
