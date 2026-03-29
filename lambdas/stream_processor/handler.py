"""
cloudpulse/lambdas/stream_processor/handler.py

Stream Processor Lambda — triggered by Kinesis Data Stream.

Reads batches of analytics events from the stream, then atomically
increments per-minute counters in DynamoDB so the realtime dashboard
can show events-per-minute, error rate, and active session counts.

DynamoDB schema
---------------
Table: cloudpulse-{env}-realtime
  PK (metric)   : "events#<event_type>"  e.g. "events#page_view"
                  "sessions#<minute>"    e.g. "sessions#2026-03-14T10:45"
  SK (minute)   : ISO minute bucket     e.g. "2026-03-14T10:45"
  count         : Number — atomic ADD counter
  expires_at    : Number — Unix timestamp (now + 86400 s) — TTL attribute

Flow
----
Kinesis stream record → base64 decode → JSON parse → DynamoDB ADD
"""

from __future__ import annotations

import base64
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

_param_cache: dict[str, str] = {}
_TTL_SECONDS = 86400  # 24 hours


def _get_parameter(name: str) -> str:
    if name not in _param_cache:
        resp = _ssm.get_parameter(Name=name, WithDecryption=True)
        _param_cache[name] = resp["Parameter"]["Value"]
    return _param_cache[name]


def _minute_bucket(timestamp_str: str) -> str:
    """Truncate an ISO timestamp to minute precision: '2026-03-14T10:45'."""
    try:
        # Handles both 'Z' suffix and '+00:00' offset
        ts = timestamp_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(ts)
    except (ValueError, AttributeError):
        dt = datetime.now(tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M")


def _process_record(table: Any, record: dict) -> None:
    """Decode one Kinesis record and update DynamoDB counters."""
    raw = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
    event = json.loads(raw)

    event_type = event.get("event_type", "unknown")
    session_id = event.get("session_id", "")
    timestamp = event.get("timestamp", datetime.now(tz=timezone.utc).isoformat())

    minute = _minute_bucket(timestamp)
    expires_at = int(time.time()) + _TTL_SECONDS

    # Increment per-event-type counter
    table.update_item(
        Key={"metric": f"events#{event_type}", "minute": minute},
        UpdateExpression="ADD #cnt :inc SET expires_at = :ttl",
        ExpressionAttributeNames={"#cnt": "count"},
        ExpressionAttributeValues={":inc": 1, ":ttl": expires_at},
    )

    # Track unique sessions: store session_id as a set per minute
    if session_id:
        table.update_item(
            Key={"metric": "sessions#active", "minute": minute},
            UpdateExpression="ADD sessions :sess SET expires_at = :ttl",
            ExpressionAttributeValues={
                ":sess": {session_id},
                ":ttl": expires_at,
            },
        )


def handler(event: dict, context: Any) -> dict:
    """
    Lambda handler invoked by Kinesis event source mapping.

    Kinesis delivers records in batches. On partial failure the entire
    batch is retried (bisect_on_function_error = true in Terraform splits
    the batch to isolate the bad record).
    """
    env = os.environ.get("ENVIRONMENT", "dev")
    table_name = _get_parameter(f"/cloudpulse/{env}/dynamodb_table")
    table = _dynamodb.Table(table_name)

    records = event.get("Records", [])
    processed = 0
    failed = 0
    batch_item_failures: list[dict[str, str]] = []

    for record in records:
        try:
            _process_record(table, record)
            processed += 1
        except Exception as exc:
            logger.error(f"Failed to process record {record['kinesis']['sequenceNumber']}: {exc}")
            failed += 1
            batch_item_failures.append(
                {"itemIdentifier": record["kinesis"]["sequenceNumber"]}
            )

    logger.info(f"Stream batch: processed={processed} failed={failed} total={len(records)}")

    # Report partial batch failures so only failed records are retried
    # Requires function_response_types=["ReportBatchItemFailures"] in Terraform
    return {"batchItemFailures": batch_item_failures}
