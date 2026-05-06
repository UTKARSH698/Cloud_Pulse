<div align="center">

# CloudPulse

### Serverless Analytics Pipeline — Lambda Architecture on AWS

[![Python](https://img.shields.io/badge/Python-3.11-blue?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![Terraform](https://img.shields.io/badge/Terraform-IaC-7B42BC?style=flat-square&logo=terraform&logoColor=white)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-Serverless-FF9900?style=flat-square&logo=amazonaws&logoColor=white)](https://aws.amazon.com)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

</div>

---

## What This Project Demonstrates

- **Lambda Architecture** — dual-path ingestion: Kinesis speed layer (< 10s lag) + SQS/S3/Athena batch layer (minutes). Both paths run in parallel; speed layer failure does not cause data loss.
- - **Hive-partitioned S3 data lake** — `events/year=.../month=.../day=.../event_type=.../` — Glue discovers partitions automatically; Athena prunes irrelevant folders. A WHERE clause on a single day scans 1/90th of a 90-day dataset.
  - - **Cognito JWT auth at the API layer** — authentication enforced entirely at API Gateway, not in Lambda code. Expired or tampered tokens never reach compute.
    - - **IAM least-privilege** — 8 IAM roles, each scoped to exactly the resources its Lambda needs. No role has `s3:DeleteObject`, `iam:*`, or wildcard ARNs.
      - - **Full CI/CD pipeline** — GitHub Actions: test → frontend-test → Terraform plan → apply → smoke test → Glue crawler start.
        - - **Operates within AWS Free Tier** — Kinesis (~$0.36/day) and Firehose (~$0.01/GB) are the only non-free components.
         
          - ---

          ## Architecture

          ```
          Client
            │
            ▼
          API Gateway (Cognito JWT auth · 10 rps throttle)
            │
            ├──► Ingest λ ──► SQS ──────────► Worker λ ──► S3 data lake
            │               (batch path)                  (Hive partitioned)
            │         │                                         │
            │         └──► Kinesis ──► Stream Processor λ      Glue Crawler
            │              (speed path)        │                │
            │                          DynamoDB              Glue Catalog
            │                       (24h TTL counters)          │
            ├──► Realtime λ ◄── DynamoDB         ◄────────── Athena
            └──► Query λ ◄──────────────────────────────────────┘
          ```

          **Batch path:** Ingest → SQS → Worker → S3 → Glue → Athena → `GET /query`
          **Speed path:** Ingest → Kinesis → Stream Processor → DynamoDB → `GET /realtime`

          If Kinesis is unavailable, ingest continues via the SQS batch path — no data loss, only real-time dashboard staleness.

          ---

          ## Key Features

          | Feature | Implementation |
          |---|---|
          | Dual-path ingestion | SQS (durable batch) + Kinesis (fail-open speed) |
          | Real-time dashboard | Pre-aggregated DynamoDB counters, P50 ~12ms |
          | Historical analytics | Serverless Athena SQL on Hive-partitioned S3 |
          | Auth | Cognito JWT — validated at API Gateway before Lambda invocation |
          | Infrastructure as Code | 15 Terraform files covering all AWS resources |
          | CI/CD | GitHub Actions: test → plan → apply → smoke test |
          | Frontend | React + Vite dashboard — event counts, timeseries, session analytics |

          ---

          ## Performance

          | Metric | Value |
          |---|---|
          | Ingest P50 latency | ~55ms |
          | Ingest P99 latency | ~120ms |
          | Kinesis → DynamoDB lag | < 10s |
          | `GET /realtime` P50 | ~12ms (DynamoDB read) |
          | Athena query (event_count) | ~1.8s avg |
          | Athena bytes scanned cap | 100MB per query |
          | Batch input size | 1,000 events / batch |

          ---

          ## Tech Stack

          `Python 3.11` `AWS Lambda` `Kinesis Data Streams` `SQS` `S3` `Athena` `DynamoDB` `Glue` `API Gateway` `Cognito` `Terraform` `React` `Vite` `GitHub Actions`

          ---

          ## Engineering Highlights

          **Fail-open speed layer** — the ingest Lambda writes to SQS first (durable), then to Kinesis (fail-open). If Kinesis is unavailable, the event is still persisted via the batch path. The speed-layer failure degrades to stale real-time data, not data loss.

          **Athena as the query engine** — Athena charges only for bytes scanned. With Hive partitioning, a single-day query on a 90-day dataset scans 1/90th of the data. A 100MB scan cap at the Athena workgroup level limits worst-case cost to ~$0.0005 per query. Redshift would cost ~$0.25/hr at idle — not appropriate for a low-traffic analytics workload.

          **Glue Crawler vs. manual partition registration** — the crawler auto-discovers new S3 partition prefixes and registers them in the Glue Data Catalog. The alternative (calling `ALTER TABLE ADD PARTITION` from the ingest Lambda) would couple two services and grant the ingest Lambda Glue write permissions.

          **Parameter Store over Lambda env vars** — Lambda environment variables are visible to anyone with `GetFunctionConfiguration`. SSM Parameter Store values are encrypted and access-controlled independently from function config.

          **CAP tension** — the speed layer (DynamoDB, eventually consistent) and batch layer (Athena on S3) can diverge on event counts for the same time window. This is an accepted trade-off, but if the real-time dashboard is used for anomaly detection, speed-layer staleness can suppress a genuine security signal. See [TECHNICAL.md](TECHNICAL.md).

          ---

          ## Quick Start

          ```bash
          git clone https://github.com/UTKARSH698/Cloud_Pulse
          cd Cloud_Pulse

          # Deploy infrastructure
          cd terraform
          terraform init
          terraform plan -var="environment=dev" -var="aws_region=us-east-1"
          terraform apply -var="environment=dev" -var="aws_region=us-east-1"

          # Create test user and get token (Terraform outputs the commands)
          terraform output quick_start

          # Seed sample data
          python scripts/seed_events.py --api-url $API --token $TOKEN --events 500

          # Run tests (no AWS credentials needed)
          pytest tests/ -v --cov=lambdas
          ```

          ---

          ## Project Structure

          ```
          cloudpulse/
          ├── lambdas/
          │   ├── ingest/          # Validate + dual-write (SQS + Kinesis)
          │   ├── worker/          # SQS consumer — writes events to S3
          │   ├── stream_processor/ # Kinesis consumer — atomic DynamoDB counters
          │   ├── realtime/        # DynamoDB query — last-5-min metrics
          │   └── query/           # Athena poll + result fetch
          ├── terraform/           # 15 .tf files — all AWS resources as code
          ├── frontend/            # React + Vite dashboard
          ├── tests/               # moto mocks — no AWS credentials needed
          ├── scripts/
          │   └── seed_events.py
          ├── TECHNICAL.md         # Lambda Architecture analysis, CAP tradeoffs, scaling
          └── .github/workflows/   # CI/CD pipeline
          ```

          ---

          ## Known Limitations

          - Speed layer and batch layer can diverge on event counts for the same window (no reconciliation)
          - - Glue Crawler must run manually to expose new S3 partitions to Athena
            - - No event deduplication on the ingest path (duplicate POSTs result in duplicate events in S3)
              - - Single Kinesis shard — 1,000 records/sec ceiling
               
                - See **[TECHNICAL.md](TECHNICAL.md)** for full analysis including CAP theorem reasoning and production architecture.
               
                - ---

                *MIT License · Utkarsh Batham*
