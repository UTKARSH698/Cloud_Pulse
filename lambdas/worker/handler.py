"""
cloudpulse/lambdas/worker/handler.py

Worker Lambda — SQS consumer that persists analytics events to S3.

Flow
----
SQS queue (events)
  → THIS Lambda  (triggered by SQS event source mapping, batch_size=10)
      1. Read S3 bucket name from Parameter Store (cached per container)
      2. For each SQS record in the batch:
         a. Parse message body  { "s3_key": "...", "record": {...} }
         b. Write the record JSON to s3://{bucket}/{s3_key}
      3. On any error: raise so Lambda marks the message as not-deleted
         → SQS retries (visibility timeout), then DLQ after maxReceiveCount

Why async, not in-line with the ingest Lambda?
----------------------------------------------
The ingest Lambda runs inside the API Gateway 3-second timeout window.
Moving the S3 write here means:
  - API callers see 200 the moment the message is enqueued to SQS.
  - S3 transient errors are retried silently via SQS — they never
    surface as 207 partial-failure responses.
  - Worker concurrency can be throttled independently of API Gateway
    without affecting the ingest throughput visible to callers.

SQS message format (set by ingest Lambda)
-----------------------------------------
{
  "s3_key": "events/year=2026/month=03/day=15/event_type=page_view/<uuid>.json",
  "record": {
    "event_id":   "<uuid>",
    "event_type": "page_view",
    "timestamp":  "2026-03-15T10:00:00+00:00",
    ...
  }
}

The s3_key is pre-computed by the ingest Lambda so both sides agree
on the Hive-partitioned layout without duplicating the key formula.

Environment variables
---------------------
ENVIRONMENT   dev | staging | prod   (set by Terraform, default: dev)

Parameter Store keys (read at runtime)
---------------------------------------
/cloudpulse/{env}/s3_bucket   — target S3 data lake bucket name
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# AWS clients — module-level for Lambda container reuse
# ---------------------------------------------------------------------------

_s3  = boto3.client("s3")
_ssm = boto3.client("ssm")

_param_cache: dict[str, str] = {}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_parameter(name: str) -> str:
    """Fetch from Parameter Store with in-process caching."""
    if name not in _param_cache:
        try:
            resp = _ssm.get_parameter(Name=name, WithDecryption=True)
            _param_cache[name] = resp["Parameter"]["Value"]
            logger.info(f"Loaded SSM parameter: {name}")
        except ClientError as exc:
            logger.error(f"Cannot fetch SSM parameter '{name}': {exc}")
            raise
    return _param_cache[name]


def _write_to_s3(bucket: str, s3_key: str, record: dict[str, Any]) -> None:
    """
    Write one event record to S3.

    Raises ClientError on failure — the caller lets the exception
    propagate so Lambda's SQS integration marks the message for retry.
    """
    _s3.put_object(
        Bucket=bucket,
        Key=s3_key,
        Body=json.dumps(record, ensure_ascii=False, default=str),
        ContentType="application/json",
    )
    logger.info(f"Written → s3://{bucket}/{s3_key}")


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------


def handler(event: dict, context: Any) -> None:
    """
    SQS-triggered Lambda handler.

    Processes each record in the batch; raises on any failure so SQS
    retries the unprocessed messages and eventually moves them to the DLQ.

    Partial-batch failure mode is not enabled, so if one record in a
    batch fails the entire batch is retried. Batch size is kept small
    (10) to limit the blast radius of a single bad message.
    """
    env       = os.environ.get("ENVIRONMENT", "dev")
    s3_bucket = _get_parameter(f"/cloudpulse/{env}/s3_bucket")

    for sqs_record in event["Records"]:
        message_id = sqs_record.get("messageId", "?")
        try:
            body   = json.loads(sqs_record["body"])
            s3_key = body["s3_key"]
            record = body["record"]
        except (json.JSONDecodeError, KeyError) as exc:
            # Malformed message — log and raise so it lands in DLQ after retries
            logger.error(f"messageId={message_id}: malformed SQS body — {exc}")
            raise

        _write_to_s3(s3_bucket, s3_key, record)
        logger.info(f"messageId={message_id} processed OK")
