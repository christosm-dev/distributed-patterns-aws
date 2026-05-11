#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="http://localhost:4566"
AWS="aws --endpoint-url=$ENDPOINT"

section() { echo ""; echo "── $* ──"; }

section "Lambda functions"
$AWS lambda list-functions \
  --query 'Functions[*].FunctionName' --output table 2>/dev/null

section "SQS queues"
$AWS sqs list-queues \
  --query 'QueueUrls' --output table 2>/dev/null

section "DynamoDB tables"
$AWS dynamodb list-tables \
  --query 'TableNames' --output table 2>/dev/null

section "S3 buckets"
$AWS s3 ls 2>/dev/null

section "SNS topics"
$AWS sns list-topics \
  --query 'Topics[*].TopicArn' --output table 2>/dev/null

section "ECS clusters"
$AWS ecs list-clusters \
  --query 'clusterArns' --output table 2>/dev/null

section "Step Functions state machines"
$AWS stepfunctions list-state-machines \
  --query 'stateMachines[*].name' --output table 2>/dev/null

section "Load balancers"
$AWS elbv2 describe-load-balancers \
  --query 'LoadBalancers[*].LoadBalancerName' --output table 2>/dev/null

echo ""
