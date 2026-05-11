# Distributed Systems Patterns on AWS

A practical implementation of distributed systems design patterns using AWS services, running locally via [LocalStack](https://localstack.cloud/). Each project implements one or more patterns from *Designing Distributed Systems* by Brendan Burns, using Python, Terraform, and AWS SAM.

The goal is to build working, observable systems that demonstrate how classical distributed patterns translate into concrete AWS infrastructure — not toy examples, but systems with realistic failure handling, observability, and separation of concerns.

---

## Patterns Covered

| Project | Pattern(s) | Key AWS Services |
|---|---|---|
| [01 — Sidecar Logging](#project-01--sidecar-logging) | Sidecar | ECS, S3, Fluent Bit |
| [02 — Ambassador Messaging](#project-02--ambassador-messaging) | Ambassador | Lambda, SQS, DLQ, SSM |
| [03 — Load-Balanced API](#project-03--load-balanced-api) | Replicated load-balanced services | ECS Fargate, ALB, Auto Scaling, DynamoDB |
| [04 — Scatter/Gather Search](#project-04--scattergather-search) | Scatter/Gather | Step Functions, Lambda, DynamoDB, S3 |
| [05 — Event-Driven Pipeline](#project-05--event-driven-pipeline) | Event-driven batch processing | API Gateway, SNS, SQS, Lambda, DynamoDB |
| [06 — Work Queue + Adapter](#project-06--work-queue--adapter) | Work queue, Adapter | SQS, Lambda, ECS, DynamoDB, CloudWatch |

---

## Architecture Overview

All six projects share a common LocalStack environment and a set of reusable Terraform modules. Each project deliberately builds on the primitives introduced by the previous ones.

```
+----------------------------------------------------------------------+
|                       LocalStack (port 4566)                         |
|                                                                      |
|  +----------+  +----------+  +----------+  +----------+             |
|  |   ECS    |  |  Lambda  |  |   SQS    |  | DynamoDB |             |
|  | 01, 03   |  |02,04,05,6|  |02,05,06  |  |04,05,06  |             |
|  +----------+  +----------+  +----------+  +----------+             |
|                                                                      |
|  +----------+  +----------+  +----------+  +------------------+     |
|  |   SNS    |  |    S3    |  |   SSM    |  |  Step Functions  |     |
|  |   05     |  |01,04,05  |  |   02     |  |       04         |     |
|  +----------+  +----------+  +----------+  +------------------+     |
+----------------------------------------------------------------------+
```

---

## Prerequisites

### Required tools

| Tool | Purpose | Install |
|---|---|---|
| Docker + Docker Compose | LocalStack and ECS containers | [docs.docker.com](https://docs.docker.com/get-docker/) |
| OpenTofu or Terraform >= 1.5 | Infrastructure as code | [opentofu.org](https://opentofu.org/docs/intro/install/) |
| AWS SAM CLI | Lambda local testing | `pip install aws-sam-cli` |
| Python >= 3.11 | Lambda handlers and tooling | [python.org](https://www.python.org/downloads/) |
| awslocal | AWS CLI wrapper for LocalStack | `pip install awscli-local` |

### NixOS / nix-direnv

A `shell.nix` and `.envrc` are provided for a reproducible development environment. With `nix-direnv` configured, the environment activates automatically on `cd`:

```bash
direnv allow  # run once after cloning
```

This gives you Python, Docker, awslocal, and SAM CLI (via virtualenv). LocalStack credentials and `AWS_ENDPOINT_URL` are exported automatically via `.envrc`.

---

## LocalStack Setup

All projects share a single LocalStack instance. Start it once before working on any project:

```bash
cd localstack
docker compose up -d
```

Verify it is running:

```bash
awslocal s3 ls
# Should return an empty list without error
```

LocalStack exposes all AWS services on a single gateway: `http://localhost:4566`.

All Terraform projects redirect AWS API calls to LocalStack via the provider configuration:

```hcl
provider "aws" {
  region                      = "eu-west-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3            = "http://localhost:4566"
    sqs           = "http://localhost:4566"
    lambda        = "http://localhost:4566"
    # all services on the same endpoint
  }
}
```

SAM local invocations use the following environment variable block (see `env.json` in each SAM project):

```json
{
  "FunctionName": {
    "AWS_ENDPOINT_URL": "http://host.docker.internal:4566",
    "AWS_ACCESS_KEY_ID": "test",
    "AWS_SECRET_ACCESS_KEY": "test",
    "AWS_DEFAULT_REGION": "eu-west-1"
  }
}
```

Note: SAM runs Lambda functions inside Docker containers — they cannot reach LocalStack via `localhost`. Use the following endpoint depending on your environment:

| Environment | SAM → LocalStack endpoint |
|---|---|
| macOS | `http://host.docker.internal:4566` |
| Windows (Docker Desktop) | `http://host.docker.internal:4566` |
| WSL2 (Docker Desktop integration) | `http://host.docker.internal:4566` |
| Linux (native Docker) | `http://172.17.0.1:4566` |

The `env.json` files in each SAM project use `host.docker.internal:4566` by default, which covers macOS, Windows, and WSL2 with Docker Desktop.

### Stopping LocalStack

```bash
cd localstack && docker compose down
```

State is ephemeral by default. This is intentional: if infrastructure cannot be recreated from code, it should not exist.

---

## Repository Structure

```
distributed-patterns-aws/
├── localstack/
│   └── docker-compose.yml          # Shared LocalStack instance
├── terraform/
│   ├── provider.tf                 # Reference LocalStack provider config
│   ├── modules/                    # Reusable Terraform modules
│   │   ├── sqs/                    # SQS queue + DLQ
│   │   ├── dynamodb/               # DynamoDB table with optional TTL and GSI
│   │   ├── iam/                    # IAM roles and inline/managed policies
│   │   ├── s3/                     # S3 bucket
│   │   └── lambda/                 # Lambda function + zip packaging
│   └── projects/
│       ├── 01-sidecar/
│       ├── 02-ambassador/
│       ├── 03-load-balanced/
│       ├── 04-scatter-gather/
│       ├── 05-event-pipeline/
│       └── 06-work-queue/
├── sam/
│   ├── 02-ambassador/
│   ├── 04-scatter-gather/
│   ├── 05-event-pipeline/
│   └── 06-work-queue/
├── docker/
│   ├── flask-api/                  # Main API container (Projects 01, 03)
│   │   ├── app.py
│   │   ├── Dockerfile
│   │   ├── docker-compose.yml      # Local dev: main + sidecar
│   │   ├── fluent-bit.conf         # Sidecar log shipping config
│   │   └── requirements.txt
│   └── log-producer/               # Batch work producer (Project 06)
├── docs/
└── shell.nix
```

---

## Project 01 — Sidecar Logging

**Pattern:** Sidecar

### Concept

The sidecar pattern attaches a secondary process to a primary application container. The two containers share resources — a network namespace and a volume — but have entirely separate responsibilities. The main application is unaware of the sidecar. It writes to stdout or a shared volume; the sidecar handles all cross-cutting concerns: log collection, TLS termination, configuration synchronisation.

The invariant is that the main application container remains unchanged regardless of which sidecar is attached. You can swap the sidecar (Fluent Bit → Logstash, for example) without touching application code.

```
+------------------------------------------+
|              ECS Task                    |
|                                          |
|  +--------------+   shared volume        |
|  |  Flask API   | ──────────────────►    |
|  |  (main)      |   /var/log/app/app.log  |
|  +--------------+                        |
|                                          |
|  +--------------+                        |
|  |  Fluent Bit  | ─────────────────► S3  |
|  |  (sidecar)   |   tail + ship          |
|  +--------------+                        |
+------------------------------------------+
```

### What is built

- A Python Flask API (`/health`, `/items` GET/POST) that writes structured JSON logs to a shared volume and stdout. Zero knowledge of Fluent Bit.
- A Fluent Bit sidecar container that tails the log file from the shared volume and ships batches to a LocalStack S3 bucket.
- An ECS task definition with a shared `app-logs` volume. The sidecar is `essential: false` — if it crashes, the application continues.
- A Docker Compose file for local development that replicates the ECS task structure against LocalStack.

### Key design decisions

- Application logs only to stdout and a file. No SDK, no external dependency, no knowledge of the transport.
- Structured JSON logs let Fluent Bit parse and enrich fields without regex.
- Sidecar is non-essential: log shipping failures must not impact application availability.
- Fluent Bit S3 endpoint overridden via environment variable to point at LocalStack — no code changes between local and real AWS.

### Running

```bash
# 1. Start LocalStack
cd localstack && docker compose up -d

# 2. Provision S3 bucket and ECS resources
cd terraform/projects/01-sidecar
tofu init && tofu apply

# 3. Run locally with Docker Compose
cd docker/flask-api
docker compose up --build

# 4. Generate log entries
curl http://localhost:5000/health
curl http://localhost:5000/items
curl -X POST http://localhost:5000/items \
  -H "Content-Type: application/json" \
  -d '{"name": "test-item"}'

# 5. Verify logs have landed in S3
awslocal s3 ls s3://sidecar-logs/ --recursive
```

---

## Project 02 — Ambassador Messaging

**Pattern:** Ambassador

### Concept

The ambassador pattern places a proxy between an application and an external service. The application calls a known local interface — the ambassador. The ambassador handles the complexity of the real external system: retries, routing, circuit breaking, environment-specific configuration.

The producer has no direct dependency on SQS. Swapping the transport layer requires changes only to the ambassador Lambda, not to the producer.

```
+--------------+  invoke  +--------------+  send   +--------------+
|   Producer   | ───────► |  Ambassador  | ──────► |  SQS Queue   |
|   Lambda     |          |  Lambda      |         +--------------+
+--------------+          +--------------+                |
                                 |                  (on max retries)
                                 | SSM                    v
                                 +──► queue URL    +--------------+
                                                   |     DLQ      |
                                                   +--------------+
```

### What is built

- Producer Lambda: generates a message payload and invokes the ambassador synchronously.
- Ambassador Lambda: reads queue URL from SSM Parameter Store, sends to SQS with exponential backoff, raises structured error on permanent failure.
- Consumer Lambda: triggered by SQS events, processes messages, logs results.
- SQS queue + DLQ: messages exceeding `maxReceiveCount` route to the DLQ automatically.
- CloudWatch alarm on DLQ depth — non-empty DLQ triggers an alert.

### Key design decisions

- Producer has no SQS imports — cannot accidentally bypass the ambassador.
- Queue URL in SSM enables environment-specific routing at the ambassador layer without code changes.
- Exponential backoff in the ambassador prevents thundering herd on transient SQS failures.

### Running

```bash
cd terraform/projects/02-ambassador
tofu init && tofu apply

cd sam/02-ambassador
sam local invoke ProducerFunction \
  --event events/produce.json \
  --env-vars env.json

awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/ambassador-queue \
  --attribute-names ApproximateNumberOfMessages
```

---

## Project 03 — Load-Balanced API

**Pattern:** Replicated load-balanced services

### Concept

Multiple identical, stateless replicas of a service run behind a load balancer. Each request is routed to any available replica. All state that persists across requests must live in an external store — a service holding state in memory gives inconsistent results when replicated.

```
             +-----------------------------+
             |  Application Load Balancer  |
             +-------------+---------------+
                  +─────────+─────────+
                  v         v         v
             +--------+ +------+ +------+
             |Flask   | |Flask | |Flask |  ECS Fargate
             |Rep. 1  | |Rep.2 | |Rep.3 |
             +--------+ +------+ +------+
                  +─────────+─────────+
                            v
                      +----------+
                      | DynamoDB |  shared state
                      +----------+
```

### What is built

- Flask API extended with a `/counter` endpoint backed by DynamoDB, demonstrating why shared state must be externalised.
- ECS Fargate service running 3 replicas behind an ALB.
- Application Auto Scaling between 2 and 10 replicas, targeting 60% CPU.
- DynamoDB atomic increment (`ADD`) to prevent lost updates across concurrent replicas.

### Key design decisions

- `/counter` uses a DynamoDB conditional update — atomic, no read-modify-write race.
- Health check returns 200 without touching DynamoDB — database slowdown does not trigger replica removal.
- Auto Scaling target at 60% leaves headroom before the service saturates.

### Running

```bash
cd docker/flask-api && docker build -t flask-api:local .
cd terraform/projects/03-load-balanced
tofu init && tofu apply
for i in $(seq 1 5); do curl http://localhost:8080/counter; done
```

---

## Project 04 — Scatter/Gather Search

**Pattern:** Scatter/Gather

### Concept

A root node receives a request and fans it out to multiple independent leaf nodes in parallel. Each leaf processes a subproblem. The root aggregates all leaf results into a single response.

Total latency is determined by the slowest leaf. Timeout handling and partial result tolerance are first-class design concerns — the system must decide what to do when a leaf is slow or fails.

```
             +----------------------+
             |   Step Functions     |
             |   State Machine      |
             |                      |
             |  +----------------+  |
             |  |   Parallel     |  |   scatter
             |  | +-----------+  |  |
             |  | | Source A  |  |  |
             |  | +-----------+  |  |
             |  | | Source B  |  |  |
             |  | +-----------+  |  |
             |  | | Source C  |  |  |
             |  | +-----------+  |  |
             |  +----------------+  |
             |          |           |
             |  +-------v--------+  |
             |  |  Aggregator    |  |   gather
             |  +----------------+  |
             +----------+-----------+
                        |
                   +----v----+
                   |   S3    |  results
                   +---------+
```

### What is built

- Step Functions standard workflow with a `Parallel` state fanning out to three Lambda functions, each querying a different DynamoDB table.
- Aggregator Lambda merging parallel results and writing to S3.
- `Choice` state handling partial failures: two-of-three success proceeds; all-fail transitions to an error state.
- Per-branch timeouts preventing slow leaves from blocking aggregation indefinitely.

### Key design decisions

- Step Functions `Parallel` state handles fan-out and fan-in natively — no coordination code required.
- Partial tolerance: aggregator proceeds with available results rather than requiring all branches to succeed.
- S3 result key derived from execution ID — natural audit trail for every search.

### Running

```bash
cd terraform/projects/04-scatter-gather
tofu init && tofu apply

awslocal stepfunctions start-execution \
  --state-machine-arn arn:aws:states:eu-west-1:000000000000:stateMachine:scatter-gather \
  --input '{"query": "distributed systems"}'

awslocal s3 ls s3://scatter-gather-results/ --recursive
```

---

## Project 05 — Event-Driven Pipeline

**Pattern:** Event-driven batch processing

### Concept

Processing stages are decoupled by queues. Each stage consumes events from its input queue, processes them, and emits to the next stage. No stage has a direct dependency on any other — they communicate only through the queue contract.

This provides resilience (a slow downstream stage does not block upstream), independent scaling (each stage scales on its own queue depth), and replay (failed messages can be reprocessed without re-running the entire pipeline).

```
API Gateway ──► Lambda     ──► SNS Topic ──► SQS Queue A ──► Lambda (process)
               (ingest)                 +──► SQS Queue B ──► Lambda (notify)
                                                                   |
                                                             DynamoDB + S3
```

### What is built

- Ingest Lambda behind API Gateway: validates payload, publishes to SNS.
- SNS fan-out to two SQS queues: processing and notification.
- Processing Lambda: deduplicates against DynamoDB (TTL-based), scores items, stores results.
- Notification Lambda: writes summary to S3.
- DynamoDB table with TTL for dedup window expiry and a GSI for top-N score queries.

### Key design decisions

- SNS fan-out decouples ingest from all downstream consumers. New consumers subscribe to the topic without touching the ingest Lambda.
- TTL-based deduplication requires no cleanup job — DynamoDB ages out records automatically.
- GSI on score enables top-N queries without a full table scan.

### Running

```bash
cd terraform/projects/05-event-pipeline
tofu init && tofu apply

curl -X POST http://localhost:4566/restapis/.../prod/ingest \
  -H "Content-Type: application/json" \
  -d '{"id": "item-001", "title": "Test Item", "source": "api"}'

awslocal dynamodb scan --table-name pipeline-items
```

---

## Project 06 — Work Queue + Adapter

**Pattern:** Work queue systems / Adapter

### Concept

**Work queue:** A producer places work items on a queue. A pool of competing consumers processes items concurrently. Each item is processed by exactly one worker. The queue provides back-pressure, durability, and load distribution.

**Adapter:** Normalises heterogeneous worker outputs into a standard schema before persistence. The adapter manages the output contract independently of the workers — worker implementations can change without affecting downstream consumers of the normalised output.

```
ECS Producer ──► SQS Queue ──► Lambda Worker 1 ──+
                           +──► Lambda Worker 2 ──+──► Adapter Lambda ──► DynamoDB
                           +──► Lambda Worker 3 ──+         |
                                                       CloudWatch Metrics
```

### What is built

- ECS batch producer (Python): generates work items, writes to SQS in batches of 10.
- Three competing Lambda consumers triggered by SQS, processing batches independently.
- Adapter Lambda: normalises heterogeneous worker output to a standard schema, writes to DynamoDB.
- CloudWatch custom metrics: queue depth, processing throughput, adapter errors.
- DynamoDB table with GSI for querying results by worker ID.

### Key design decisions

- SQS visibility timeout exceeds maximum Lambda runtime — a message never re-appears while being processed.
- Adapter is a separate Lambda, not logic embedded in workers — normalisation contract evolves independently.
- CloudWatch metrics pushed from both producer and adapter — end-to-end pipeline visibility without a dedicated monitoring service.

### Running

```bash
cd terraform/projects/06-work-queue
tofu init && tofu apply

docker run --network ministack-net \
  -e AWS_ENDPOINT_URL=http://ministack:4566 \
  -e AWS_ACCESS_KEY_ID=test \
  -e AWS_SECRET_ACCESS_KEY=test \
  -e QUEUE_URL=http://ministack:4566/000000000000/work-queue \
  log-producer:local

watch -n 2 "awslocal sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/work-queue \
  --attribute-names ApproximateNumberOfMessages"

awslocal dynamodb scan --table-name work-results
```

---

## Common Conventions

### Infrastructure

- All Terraform projects include the LocalStack provider configuration inline — no shared remote backend required for local development.
- `tofu init && tofu apply` is the single command to provision any project.
- `tofu destroy` tears everything down cleanly.
- Modules in `terraform/modules/` are referenced via relative paths from each project root.

### Python

- All Lambda handlers use the signature `def handler(event: dict, context) -> dict`.
- Structured JSON logging throughout — every entry includes `timestamp`, `level`, `function`, and contextual fields.
- `boto3` clients instantiated at module level to reuse connections across warm invocations.
- LocalStack endpoint injected via `AWS_ENDPOINT_URL` — no special casing in application code.

### SAM local testing

```bash
sam local invoke FunctionName \
  --event events/sample.json \
  --env-vars env.json
```

`env.json` format — used by every SAM project in this repo:

```json
{
  "FunctionName": {
    "AWS_ENDPOINT_URL": "http://host.docker.internal:4566",
    "AWS_ACCESS_KEY_ID": "test",
    "AWS_SECRET_ACCESS_KEY": "test",
    "AWS_DEFAULT_REGION": "eu-west-1"
  }
}
```

`host.docker.internal:4566` works on macOS, Windows, and WSL2 with Docker Desktop. On native Linux replace with `172.17.0.1:4566`.

---

## References

- Burns, B. (2018). *Designing Distributed Systems*. O'Reilly Media.
- [LocalStack documentation](https://docs.localstack.cloud/)
- [AWS Step Functions developer guide](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html)
- [AWS SQS developer guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html)
- [OpenTofu documentation](https://opentofu.org/docs/)
- [AWS SAM CLI documentation](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/what-is-sam.html)
