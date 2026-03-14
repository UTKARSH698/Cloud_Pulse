"""
cloudpulse/lambdas/ingest/handler.py

Ingest Lambda — receives analytics events from API Gateway,
validates them, and dual-writes each to S3 (batch path) and
Kinesis Data Stream (speed path / real-time analytics).

Flow
----
API Gateway (POST /events or POST /events/batch)
  → Cognito JWT authorizer (handled by API GW, not here)
  → THIS Lambda
      1. Read S3 bucket / prefix / Kinesis stream from Parameter Store (cached)
      2. Parse & validate JSON body with Pydantic
      3. Write each event as a single JSON object to S3      (batch path)
      4. Put each accepted event to Kinesis Data Stream      (speed path)
      5. Return 200 / 207 / 4xx to API Gateway

Kinesis is fail-open: if the put_record call fails, the event is still
accepted (it was already written to S3). The stream failure is logged
but does not cause a 207 partial-failure response.

Environment variables
---------------------
ENVIRONMENT   dev | staging | prod   (set by Terraform, default: dev)

Parameter Store keys (read at runtime)
---------------------------------------
/cloudpulse/{env}/s3_bucket       — target S3 bucket name
/cloudpulse/{env}/s3_prefix       — S3 key prefix (e.g. "events")
/cloudpulse/{env}/kinesis_stream  — Kinesis stream name
"""

from __future__ import annotations

import base64
import json
import logging
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError
from pydantic import ValidationError

from models import AnalyticsEvent, BatchIngestRequest, IngestResult

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# AWS clients — module-level so Lambda container reuse keeps them warm
# ---------------------------------------------------------------------------

_s3      = boto3.client("s3")
_ssm     = boto3.client("ssm")
_kinesis = boto3.client("kinesis")

# In-process cache so repeated invocations skip SSM round-trips
_param_cache: dict[str, str] = {}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_parameter(name: str) -> str:
    """
    Fetch a SecureString or String from Parameter Store.

    Result is cached for the lifetime of the Lambda container (~15 min on
    free tier). To force a refresh, redeploy or set a new container.
    """
    if name not in _param_cache:
        try:
            resp = _ssm.get_parameter(Name=name, WithDecryption=True)
            _param_cache[name] = resp["Parameter"]["Value"]
            logger.info(f"Loaded SSM parameter: {name}")
        except ClientError as exc:
            logger.error(f"Cannot fetch SSM parameter '{name}': {exc}")
            raise
    return _param_cache[name]


def _api_response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    """Format a Lambda proxy integration response for API Gateway."""
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",         # CORS — tighten in prod
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
        },
        "body": json.dumps(body, default=str),
    }


def _decode_body(raw_event: dict) -> dict | None:
    """
    Extract and JSON-parse the request body from an API Gateway proxy event.

    API Gateway may base64-encode the body for binary payloads.
    Returns None if the body is missing or unparseable.
    """
    raw = raw_event.get("body") or "{}"
    if raw_event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.warning(f"Body JSON decode failed: {exc}")
        return None


def _put_to_kinesis(event: AnalyticsEvent, stream_name: str) -> None:
    """
    Put one event record onto the Kinesis Data Stream (speed path).

    Fail-open: exceptions are logged but NOT re-raised. The caller
    should not treat a Kinesis failure as an event rejection — the
    event is already durably stored in S3.

    The partition key is the session_id so records from the same
    session land on the same shard, preserving per-session ordering.
    """
    try:
        record = event.to_s3_record()
        _kinesis.put_record(
            StreamName=stream_name,
            Data=json.dumps(record, default=str).encode("utf-8"),
            PartitionKey=str(event.session_id),
        )
        logger.debug(f"event_id={event.event_id} → Kinesis stream={stream_name}")
    except Exception as exc:
        # Fail-open: S3 write already succeeded; stream failure is non-fatal
        logger.warning(f"Kinesis put_record failed for event_id={event.event_id}: {exc}")


def _write_to_s3(event: AnalyticsEvent, bucket: str, prefix: str) -> bool:
    """
    Write one event to S3.

    Returns True on success, False on any ClientError so the caller can
    track partial failures and return HTTP 207.
    """
    key    = event.s3_key(prefix=prefix)
    record = event.to_s3_record()
    try:
        _s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=json.dumps(record, ensure_ascii=False, default=str),
            ContentType="application/json",
        )
        logger.info(f"event_id={event.event_id} written → s3://{bucket}/{key}")
        return True
    except ClientError as exc:
        logger.error(f"S3 put_object failed for event_id={event.event_id}: {exc}")
        return False


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------

def handler(event: dict, context: Any) -> dict:
    """
    Lambda handler invoked by API Gateway.

    Supported paths
    ---------------
    POST /events         — ingest a single event
    POST /events/batch   — ingest up to 100 events in one call

    Single-event body
    -----------------
    {
        "event_type": "page_view",
        "session_id": "sess_xyz",
        "source": "web",
        "properties": { "page": "/home" }
    }

    Batch body
    ----------
    {
        "events": [
            { "event_type": "click", "session_id": "sess_xyz", "source": "web" },
            ...
        ]
    }

    Responses
    ---------
    200  All events accepted
    207  Partial failure (some events accepted, some failed S3 write)
    400  Malformed JSON
    422  Validation error (schema mismatch)
    500  Service-level error (SSM unavailable, etc.)
    """
    path   = event.get("path", "")
    method = event.get("httpMethod", "POST")
    logger.info(f"Incoming request: {method} {path}")

    # ── 1. Resolve config from Parameter Store ────────────────────────────
    env = os.environ.get("ENVIRONMENT", "dev")
    try:
        s3_bucket      = _get_parameter(f"/cloudpulse/{env}/s3_bucket")
        s3_prefix      = _get_parameter(f"/cloudpulse/{env}/s3_prefix")
        kinesis_stream = _get_parameter(f"/cloudpulse/{env}/kinesis_stream")
    except ClientError:
        return _api_response(500, {"error": "Service configuration unavailable — check SSM parameters"})

    # ── 2. Parse request body ─────────────────────────────────────────────
    body = _decode_body(event)
    if body is None:
        return _api_response(400, {"error": "Request body must be valid JSON"})

    # ── 3. Validate against Pydantic models ───────────────────────────────
    is_batch = path.endswith("/batch") or isinstance(body.get("events"), list)

    if is_batch:
        # Normalise: if someone POSTs a bare event list without wrapper key
        if "events" not in body:
            body = {"events": [body]}
        try:
            batch          = BatchIngestRequest.model_validate(body)
            events_to_write = batch.events
        except ValidationError as exc:
            logger.warning(f"Batch validation failed: {exc}")
            return _api_response(422, {
                "error":   "Request validation failed",
                "details": exc.errors(include_url=False),
            })
    else:
        try:
            single         = AnalyticsEvent.model_validate(body)
            events_to_write = [single]
        except ValidationError as exc:
            logger.warning(f"Event validation failed: {exc}")
            return _api_response(422, {
                "error":   "Request validation failed",
                "details": exc.errors(include_url=False),
            })

    # ── 4. Write events to S3 ─────────────────────────────────────────────
    accepted_ids: list[str] = []
    errors:       list[dict[str, str]] = []

    for evt in events_to_write:
        if _write_to_s3(evt, s3_bucket, s3_prefix):
            accepted_ids.append(str(evt.event_id))
            # Speed path: put to Kinesis for real-time aggregation (fail-open)
            _put_to_kinesis(evt, kinesis_stream)
        else:
            errors.append({
                "event_id": str(evt.event_id),
                "reason":   "S3 write failed — see Lambda logs",
            })

    # ── 5. Build response ─────────────────────────────────────────────────
    result = IngestResult(
        accepted=len(accepted_ids),
        rejected=len(errors),
        event_ids=accepted_ids,
        errors=errors,
    )
    # HTTP 207 Multi-Status signals partial success to the caller
    status = 207 if errors else 200
    logger.info(
        f"Ingest complete: accepted={result.accepted} rejected={result.rejected}"
    )
    return _api_response(status, result.model_dump())
