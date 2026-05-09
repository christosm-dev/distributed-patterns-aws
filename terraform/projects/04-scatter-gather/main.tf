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
    dynamodb       = "http://localhost:4566"
    s3             = "http://localhost:4566"
    lambda         = "http://localhost:4566"
    iam            = "http://localhost:4566"
    stepfunctions  = "http://localhost:4566"
    logs           = "http://localhost:4566"
  }
}

# ── DynamoDB source tables ─────────────────────────────────────────────────

module "table_a" {
  source   = "../../modules/dynamodb"
  name     = "scatter-source-a"
  hash_key = "id"
  tags     = local.tags
}

module "table_b" {
  source   = "../../modules/dynamodb"
  name     = "scatter-source-b"
  hash_key = "id"
  tags     = local.tags
}

module "table_c" {
  source   = "../../modules/dynamodb"
  name     = "scatter-source-c"
  hash_key = "id"
  tags     = local.tags
}

# ── Seed data ──────────────────────────────────────────────────────────────

resource "aws_dynamodb_table_item" "a1" {
  table_name = module.table_a.table_name
  hash_key   = "id"
  item = jsonencode({ id = { S = "a1" }, title = { S = "Designing Distributed Systems" }, keywords = { S = "distributed systems patterns consistency" } })
}

resource "aws_dynamodb_table_item" "a2" {
  table_name = module.table_a.table_name
  hash_key   = "id"
  item = jsonencode({ id = { S = "a2" }, title = { S = "The CAP Theorem" }, keywords = { S = "distributed consistency availability partition" } })
}

resource "aws_dynamodb_table_item" "b1" {
  table_name = module.table_b.table_name
  hash_key   = "id"
  item = jsonencode({ id = { S = "b1" }, title = { S = "MapReduce: Simplified Data Processing" }, keywords = { S = "distributed systems mapreduce batch" } })
}

resource "aws_dynamodb_table_item" "b2" {
  table_name = module.table_b.table_name
  hash_key   = "id"
  item = jsonencode({ id = { S = "b2" }, title = { S = "Kafka: A Distributed Messaging System" }, keywords = { S = "distributed messaging streaming" } })
}

resource "aws_dynamodb_table_item" "c1" {
  table_name = module.table_c.table_name
  hash_key   = "id"
  item = jsonencode({ id = { S = "c1" }, title = { S = "Raft Consensus Algorithm" }, keywords = { S = "distributed consensus leader election" } })
}

resource "aws_dynamodb_table_item" "c2" {
  table_name = module.table_c.table_name
  hash_key   = "id"
  item = jsonencode({ id = { S = "c2" }, title = { S = "Chord: A Scalable Peer-to-Peer Lookup" }, keywords = { S = "distributed systems peer lookup" } })
}

# ── S3 results bucket ──────────────────────────────────────────────────────

module "results_bucket" {
  source = "../../modules/s3"
  name   = "scatter-gather-results"
  tags   = local.tags
}

# ── IAM roles ──────────────────────────────────────────────────────────────

module "source_role" {
  source = "../../modules/iam"
  name   = "scatter-source-role"
  tags   = local.tags

  inline_policies = {
    dynamodb-scan = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = [
          module.table_a.table_arn,
          module.table_b.table_arn,
          module.table_c.table_arn,
        ]
      }]
    })
  }
}

module "aggregator_role" {
  source = "../../modules/iam"
  name   = "scatter-aggregator-role"
  tags   = local.tags

  inline_policies = {
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

resource "aws_iam_role" "sfn_role" {
  name = "scatter-sfn-role"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_invoke" {
  name = "scatter-sfn-invoke-lambdas"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [
        module.source_a_lambda.function_arn,
        module.source_b_lambda.function_arn,
        module.source_c_lambda.function_arn,
        module.aggregator_lambda.function_arn,
      ]
    }]
  })
}

# ── Lambda functions ───────────────────────────────────────────────────────

module "source_a_lambda" {
  source     = "../../modules/lambda"
  name       = "scatter-source-a"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/source"
  role_arn   = module.source_role.role_arn
  tags       = local.tags

  environment_variables = {
    SOURCE_NAME      = "A"
    TABLE_NAME       = module.table_a.table_name
    AWS_ENDPOINT_URL = "http://172.18.0.2:4566"
  }
}

module "source_b_lambda" {
  source     = "../../modules/lambda"
  name       = "scatter-source-b"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/source"
  role_arn   = module.source_role.role_arn
  tags       = local.tags

  environment_variables = {
    SOURCE_NAME      = "B"
    TABLE_NAME       = module.table_b.table_name
    AWS_ENDPOINT_URL = "http://172.18.0.2:4566"
  }
}

module "source_c_lambda" {
  source     = "../../modules/lambda"
  name       = "scatter-source-c"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/source"
  role_arn   = module.source_role.role_arn
  tags       = local.tags

  environment_variables = {
    SOURCE_NAME      = "C"
    TABLE_NAME       = module.table_c.table_name
    AWS_ENDPOINT_URL = "http://172.18.0.2:4566"
  }
}

module "aggregator_lambda" {
  source     = "../../modules/lambda"
  name       = "scatter-aggregator"
  handler    = "handler.handler"
  source_dir = "${path.module}/lambdas/aggregator"
  role_arn   = module.aggregator_role.role_arn
  tags       = local.tags

  environment_variables = {
    S3_BUCKET        = module.results_bucket.bucket_name
    AWS_ENDPOINT_URL = "http://172.18.0.2:4566"
  }
}

# ── Step Functions state machine ───────────────────────────────────────────
# NOTE: The Terraform AWS provider v5.26+ calls ValidateStateMachineDefinition
# before creating the state machine. LocalStack does not support that API, so
# we create the state machine via a null_resource local-exec instead.

resource "null_resource" "scatter_gather_sfn" {
  triggers = {
    role_arn     = aws_iam_role.sfn_role.arn
    source_a_arn = module.source_a_lambda.function_arn
    source_b_arn = module.source_b_lambda.function_arn
    source_c_arn = module.source_c_lambda.function_arn
    aggregator   = module.aggregator_lambda.function_arn
  }

  provisioner "local-exec" {
    command = <<-EOF
      aws --endpoint-url=http://localhost:4566 stepfunctions delete-state-machine \
        --state-machine-arn arn:aws:states:eu-west-1:000000000000:stateMachine:scatter-gather 2>/dev/null || true

      aws --endpoint-url=http://localhost:4566 stepfunctions create-state-machine \
        --name scatter-gather \
        --role-arn ${aws_iam_role.sfn_role.arn} \
        --definition '${jsonencode({
          Comment = "Scatter/Gather search across three DynamoDB sources"
          StartAt = "ScatterSearch"
          States = {
            ScatterSearch = {
              Type = "Parallel", ResultPath = "$.parallel_results", Next = "GatherResults"
              Branches = [
                { StartAt = "SourceA", States = {
                    SourceA       = { Type = "Task", Resource = module.source_a_lambda.function_arn, TimeoutSeconds = 10, Catch = [{ErrorEquals = ["States.ALL"], Next = "SourceAFailed"}], End = true }
                    SourceAFailed = { Type = "Pass", Result = {source = "A", success = false, results = [], count = 0}, End = true }
                }},
                { StartAt = "SourceB", States = {
                    SourceB       = { Type = "Task", Resource = module.source_b_lambda.function_arn, TimeoutSeconds = 10, Catch = [{ErrorEquals = ["States.ALL"], Next = "SourceBFailed"}], End = true }
                    SourceBFailed = { Type = "Pass", Result = {source = "B", success = false, results = [], count = 0}, End = true }
                }},
                { StartAt = "SourceC", States = {
                    SourceC       = { Type = "Task", Resource = module.source_c_lambda.function_arn, TimeoutSeconds = 10, Catch = [{ErrorEquals = ["States.ALL"], Next = "SourceCFailed"}], End = true }
                    SourceCFailed = { Type = "Pass", Result = {source = "C", success = false, results = [], count = 0}, End = true }
                }}
              ]
            }
            GatherResults   = { Type = "Task", Resource = module.aggregator_lambda.function_arn, Next = "CheckSuccess" }
            CheckSuccess    = { Type = "Choice", Choices = [{Variable = "$.success_count", NumericEquals = 0, Next = "SearchFailed"}], Default = "SearchSucceeded" }
            SearchFailed    = { Type = "Fail", Error = "AllSourcesFailed", Cause = "All three data sources returned errors" }
            SearchSucceeded = { Type = "Succeed" }
          }
        })}'
    EOF
  }
}

locals {
  tags = {
    project = "distributed-patterns"
    pattern = "scatter-gather"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "state_machine_arn" {
  value = "arn:aws:states:eu-west-1:000000000000:stateMachine:scatter-gather"
}

output "results_bucket" {
  value = module.results_bucket.bucket_name
}
