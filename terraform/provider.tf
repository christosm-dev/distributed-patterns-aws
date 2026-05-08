# terraform/provider.tf
# Shared provider configuration for LocalStack.
# Each project's main.tf sources this via a relative path or duplicates it.
# All AWS API calls are redirected to http://localhost:4566.

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
    s3             = "http://localhost:4566"
    sqs            = "http://localhost:4566"
    sns            = "http://localhost:4566"
    lambda         = "http://localhost:4566"
    dynamodb       = "http://localhost:4566"
    ecs            = "http://localhost:4566"
    ssm            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    stepfunctions  = "http://localhost:4566"
    cloudwatch     = "http://localhost:4566"
    apigateway     = "http://localhost:4566"
    logs           = "http://localhost:4566"
  }
}
