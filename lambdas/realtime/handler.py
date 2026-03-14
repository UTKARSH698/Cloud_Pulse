"""
cloudpulse/lambdas/realtime/handler.py

Realtime Lambda — serves GET /realtime from API Gateway.

Reads the last 5 minutes of metrics from DynamoDB and returns:
  - events_per_minute  : per-event-type counts for each recent minute
  - total_events       : total events in the last 5 minutes
  - error_count        : error-type events in the last 5 minutes
  - error_rate_pct     : errors / total * 100
  - active_sessions    : unique session IDs seen in the last 5 minutes

DynamoDB schema (same table written by stream_processor)
  PK  metric  : "events#<event_type>" or "sessions#active"
  SK  minute  : "2026-03-14T10:45"
  count       : Number
  sessions    : StringSet (for active sessions metric)
  expires_at  : Number (TTL)
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_dynamodb = boto3.resource("dynamodb")
_ssm = boto3.client("ssm")

_param_cache: dict[str, str] = {}

# Event types we aggregate (must match EventType enum in ingest models)
_EVENT_TYPES = ["page_view", "click", "api_call", "form_submit", "error", "custom"]
_LOOKBACK_MINUTES = 5


def _get_parameter(name: str) -> str:
    if name not in _param_cache:
        resp = _ssm.get_parameter(Name=name, WithDecryption=True)
        _param_cache[name] = resp["Parameter"]["Value"]
    return _param_cache[name]


def _recent_minutes(n: int) -> list[str]:
    """Return last n minute-bucket strings in descending order."""
    now = datetime.now(tz=timezone.utc)
    return [
        (now - timedelta(minutes=i)).strftime("%Y-%m-%dT%H:%M")
        for i in range(n)
    ]


def _api_response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
        },
        "body": json.dumps(body, default=str),
    }


def handler(event: dict, context: Any) -> dict:
    """
    Lambda handler for GET /realtime.

    Returns aggregated real-time metrics from DynamoDB covering
    the last 5 minutes of stream-processed events.
    """
    env = os.environ.get("ENVIRONMENT", "dev")

    try:
        table_name = _get_parameter(f"/cloudpulse/{env}/dynamodb_table")
    except ClientError as exc:
        logger.error(f"SSM parameter fetch failed: {exc}")
        return _api_response(500, {"error": "Service configuration unavailable"})

    table = _dynamodb.Table(table_name)
    minutes = _recent_minutes(_LOOKBACK_MINUTES)

    # ── 1. Query per-event-type counts ───────────────────────────────────────
    events_per_minute: dict[str, dict[str, int]] = {}  # minute → {event_type: count}
    totals: dict[str, int] = {}  # event_type → total over lookback window

    for event_type in _EVENT_TYPES:
        pk = f"events#{event_type}"
        try:
            resp = table.query(
                KeyConditionExpression=Key("metric").eq(pk) & Key("minute").between(
                    minutes[-1], minutes[0]
                )
            )
        except ClientError as exc:
            logger.warning(f"DynamoDB query failed for {pk}: {exc}")
            continue

        for item in resp.get("Items", []):
            minute = item["minute"]
            count = int(item.get("count", 0))
            totals[event_type] = totals.get(event_type, 0) + count
            if minute not in events_per_minute:
                events_per_minute[minute] = {}
            events_per_minute[minute][event_type] = count

    # ── 2. Query active sessions ──────────────────────────────────────────────
    active_sessions = 0
    try:
        resp = table.query(
            KeyConditionExpression=Key("metric").eq("sessions#active") & Key("minute").between(
                minutes[-1], minutes[0]
            )
        )
        session_ids: set[str] = set()
        for item in resp.get("Items", []):
            session_ids.update(item.get("sessions", set()))
        active_sessions = len(session_ids)
    except ClientError as exc:
        logger.warning(f"Active sessions query failed: {exc}")

    # ── 3. Build summary ──────────────────────────────────────────────────────
    total_events = sum(totals.values())
    error_count = totals.get("error", 0)
    error_rate_pct = round((error_count / total_events * 100), 1) if total_events > 0 else 0.0

    # Sorted timeline for the chart (oldest first)
    timeline = [
        {
            "minute": m,
            **{et: events_per_minute.get(m, {}).get(et, 0) for et in _EVENT_TYPES},
        }
        for m in sorted(events_per_minute.keys())
    ]

    result = {
        "lookback_minutes": _LOOKBACK_MINUTES,
        "total_events": total_events,
        "error_count": error_count,
        "error_rate_pct": error_rate_pct,
        "active_sessions": active_sessions,
        "by_event_type": totals,
        "timeline": timeline,
    }

    logger.info(
        f"Realtime query: total={total_events} errors={error_count} sessions={active_sessions}"
    )
    return _api_response(200, result)
