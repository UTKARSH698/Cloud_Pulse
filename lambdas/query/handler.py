"""
cloudpulse/lambdas/query/handler.py

Query Lambda — translates HTTP query-string parameters into a pre-built
Athena SQL statement, polls for results, and returns structured JSON.

How Athena works (the async dance)
-----------------------------------
  1. start_query_execution()  → returns an execution_id
  2. Poll get_query_execution() until State ∈ {SUCCEEDED, FAILED, CANCELLED}
  3. get_query_results()      → paginate through rows

This Lambda does all three steps synchronously within one invocation.
The 29-second API Gateway timeout gives us plenty of headroom; free-tier
Athena queries on small datasets finish in < 5 seconds.

Environment variables
---------------------
ENVIRONMENT   dev | staging | prod   (default: dev)

Parameter Store keys
---------------------
/cloudpulse/{env}/s3_bucket          — data lake bucket
/cloudpulse/{env}/athena_output_bucket — where Athena writes result CSVs
/cloudpulse/{env}/glue_database      — Glue Data Catalog database name
/cloudpulse/{env}/glue_table         — table name inside that database
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError
from pydantic import ValidationError

from models import QueryRequest, QueryResponse, QueryType

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# AWS clients
# ---------------------------------------------------------------------------

_athena = boto3.client("athena")
_ssm    = boto3.client("ssm")

_param_cache: dict[str, str] = {}

# Athena poll config
_POLL_INTERVAL_S = 0.5    # seconds between GetQueryExecution calls
_MAX_POLL_S      = 25     # abort if query hasn't finished within 25 s


# ---------------------------------------------------------------------------
# Parameter Store helper
# ---------------------------------------------------------------------------

def _get_parameter(name: str) -> str:
    if name not in _param_cache:
        try:
            resp = _ssm.get_parameter(Name=name, WithDecryption=True)
            _param_cache[name] = resp["Parameter"]["Value"]
            logger.info(f"Loaded SSM parameter: {name}")
        except ClientError as exc:
            logger.error(f"SSM fetch failed for '{name}': {exc}")
            raise
    return _param_cache[name]


# ---------------------------------------------------------------------------
# SQL builder
# ---------------------------------------------------------------------------

# Analogy: think of these as prepared-statement templates.
# We never interpolate user strings directly — only validated Python
# date objects and enums reach the SQL, preventing injection.

def _build_sql(req: QueryRequest, database: str, table: str) -> str:
    """
    Return a parameterised Athena SQL string for the requested query type.

    Partition pruning: every query filters on year/month/day so Athena
    skips irrelevant S3 folders entirely — critical for keeping free-tier
    data-scanned costs at zero.
    """
    # Date partition filter — covers every day in [date_from, date_to]
    # We use a simple date() cast which Athena supports natively.
    date_filter = (
        f"date(concat(cast(year as varchar),'-',"
        f"lpad(cast(month as varchar),2,'0'),'-',"
        f"lpad(cast(day as varchar),2,'0'))) "
        f"BETWEEN date '{req.date_from}' AND date '{req.date_to}'"
    )

    # Optional event_type filter (value already validated as enum member)
    type_filter = ""
    if req.event_type:
        safe_type = req.event_type.replace("'", "")   # belt-and-braces
        type_filter = f" AND event_type = '{safe_type}'"

    full_table = f'"{database}"."{table}"'

    if req.query_type == QueryType.EVENT_COUNT:
        return f"""
            SELECT
                event_type,
                COUNT(*) AS event_count
            FROM {full_table}
            WHERE {date_filter}{type_filter}
            GROUP BY event_type
            ORDER BY event_count DESC
        """.strip()

    if req.query_type == QueryType.TIMESERIES:
        return f"""
            SELECT
                date_trunc('hour', from_iso8601_timestamp(timestamp)) AS hour,
                event_type,
                COUNT(*) AS event_count
            FROM {full_table}
            WHERE {date_filter}{type_filter}
            GROUP BY 1, 2
            ORDER BY 1, 2
        """.strip()

    if req.query_type == QueryType.TOP_SESSIONS:
        return f"""
            SELECT
                session_id,
                COUNT(*) AS event_count,
                MIN(timestamp) AS session_start,
                MAX(timestamp) AS session_end
            FROM {full_table}
            WHERE {date_filter}{type_filter}
            GROUP BY session_id
            ORDER BY event_count DESC
            LIMIT {req.limit}
        """.strip()

    if req.query_type == QueryType.ERRORS:
        return f"""
            SELECT
                event_id,
                timestamp,
                session_id,
                user_id,
                properties
            FROM {full_table}
            WHERE {date_filter}
              AND event_type = 'error'
            ORDER BY timestamp DESC
            LIMIT {req.limit}
        """.strip()

    raise ValueError(f"Unhandled query type: {req.query_type}")


# ---------------------------------------------------------------------------
# Athena execution helpers
# ---------------------------------------------------------------------------

def _run_query(sql: str, output_location: str) -> str:
    """Submit query and return execution_id."""
    resp = _athena.start_query_execution(
        QueryString=sql,
        ResultConfiguration={"OutputLocation": output_location},
    )
    execution_id: str = resp["QueryExecutionId"]
    logger.info(f"Athena query submitted: execution_id={execution_id}")
    return execution_id


def _wait_for_query(execution_id: str) -> dict:
    """
    Poll until the query reaches a terminal state.

    Returns the QueryExecution dict on SUCCEEDED.
    Raises RuntimeError on FAILED / CANCELLED / timeout.
    """
    deadline = time.monotonic() + _MAX_POLL_S
    while time.monotonic() < deadline:
        resp  = _athena.get_query_execution(QueryExecutionId=execution_id)
        state = resp["QueryExecution"]["Status"]["State"]

        if state == "SUCCEEDED":
            logger.info(f"Query {execution_id} SUCCEEDED")
            return resp["QueryExecution"]

        if state in ("FAILED", "CANCELLED"):
            reason = resp["QueryExecution"]["Status"].get("StateChangeReason", "unknown")
            raise RuntimeError(f"Athena query {state}: {reason}")

        logger.debug(f"Query {execution_id} state={state}, sleeping {_POLL_INTERVAL_S}s")
        time.sleep(_POLL_INTERVAL_S)

    raise TimeoutError(f"Athena query {execution_id} did not finish within {_MAX_POLL_S}s")


def _fetch_results(execution_id: str, limit: int) -> list[dict[str, Any]]:
    """
    Paginate through Athena result pages and return rows as dicts.

    The first row Athena returns is the column-header row — we skip it
    and use the column names from ResultSetMetadata instead.
    """
    rows: list[dict[str, Any]] = []
    paginator = _athena.get_paginator("get_query_results")
    pages     = paginator.paginate(QueryExecutionId=execution_id)

    column_names: list[str] = []
    first_page = True

    for page in pages:
        result_set = page["ResultSet"]

        if first_page:
            column_names = [
                col["Label"]
                for col in result_set["ResultSetMetadata"]["ColumnInfo"]
            ]
            data_rows = result_set["Rows"][1:]   # skip header row
            first_page = False
        else:
            data_rows = result_set["Rows"]

        for row in data_rows:
            values = [field.get("VarCharValue", "") for field in row["Data"]]
            rows.append(dict(zip(column_names, values)))

            if len(rows) >= limit:
                return rows

    return rows


# ---------------------------------------------------------------------------
# API Gateway helpers
# ---------------------------------------------------------------------------

def _api_response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }


def _parse_query_params(raw_event: dict) -> dict[str, str]:
    """Extract query-string parameters; return empty dict if none."""
    return raw_event.get("queryStringParameters") or {}


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------

def handler(event: dict, context: Any) -> dict:
    """
    Lambda handler for analytics queries.

    Query-string parameters map directly to QueryRequest fields:
      ?query_type=event_count&date_from=2026-03-01&date_to=2026-03-09
      &event_type=page_view&limit=50

    Example response
    ----------------
    {
      "query_type": "event_count",
      "query_execution_id": "abc-123",
      "rows_returned": 6,
      "scanned_bytes": 4096,
      "execution_ms": 1832,
      "date_from": "2026-03-01",
      "date_to": "2026-03-09",
      "results": [
        { "event_type": "page_view", "event_count": "4210" },
        ...
      ],
      "truncated": false
    }
    """
    start_ms = int(time.monotonic() * 1000)
    logger.info(f"Query request: {event.get('path')} params={event.get('queryStringParameters')}")

    # ── 1. Load config from Parameter Store ──────────────────────────────
    env = os.environ.get("ENVIRONMENT", "dev")
    try:
        s3_bucket       = _get_parameter(f"/cloudpulse/{env}/s3_bucket")
        athena_output   = _get_parameter(f"/cloudpulse/{env}/athena_output_bucket")
        glue_database   = _get_parameter(f"/cloudpulse/{env}/glue_database")
        glue_table      = _get_parameter(f"/cloudpulse/{env}/glue_table")
    except ClientError:
        return _api_response(500, {"error": "Service configuration unavailable"})

    output_location = f"s3://{athena_output}/query-results/"

    # ── 2. Parse & validate query parameters ─────────────────────────────
    params = _parse_query_params(event)
    try:
        req = QueryRequest.model_validate(params)
    except ValidationError as exc:
        return _api_response(422, {
            "error":   "Invalid query parameters",
            "details": exc.errors(include_url=False),
        })

    # ── 3. Build SQL ──────────────────────────────────────────────────────
    try:
        sql = _build_sql(req, glue_database, glue_table)
        logger.info(f"Executing SQL:\n{sql}")
    except ValueError as exc:
        return _api_response(400, {"error": str(exc)})

    # ── 4. Run on Athena ──────────────────────────────────────────────────
    try:
        execution_id = _run_query(sql, output_location)
        execution    = _wait_for_query(execution_id)
    except (RuntimeError, TimeoutError) as exc:
        logger.error(f"Athena execution failed: {exc}")
        return _api_response(500, {"error": str(exc)})
    except ClientError as exc:
        logger.error(f"Athena API error: {exc}")
        return _api_response(500, {"error": "Athena service error"})

    # ── 5. Fetch results ──────────────────────────────────────────────────
    try:
        rows = _fetch_results(execution_id, limit=req.limit)
    except ClientError as exc:
        logger.error(f"Failed to fetch Athena results: {exc}")
        return _api_response(500, {"error": "Could not retrieve query results"})

    # Athena reports bytes scanned — handy for cost awareness in the README
    stats         = execution.get("Statistics", {})
    scanned_bytes = stats.get("DataScannedInBytes", 0)
    end_ms        = int(time.monotonic() * 1000)

    response = QueryResponse(
        query_type=req.query_type,
        query_execution_id=execution_id,
        rows_returned=len(rows),
        scanned_bytes=scanned_bytes,
        execution_ms=end_ms - start_ms,
        date_from=str(req.date_from),
        date_to=str(req.date_to),
        results=rows,
        truncated=len(rows) == req.limit,
    )

    logger.info(
        f"Query complete: rows={response.rows_returned} "
        f"scanned={scanned_bytes}B exec={response.execution_ms}ms"
    )
    return _api_response(200, response.model_dump())
