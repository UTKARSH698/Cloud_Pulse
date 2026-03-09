"""
tests/test_query.py

Unit tests for the query Lambda (lambdas/query/handler.py).

Athena is async, so three boto3 calls are mocked:
  - athena.start_query_execution()
  - athena.get_query_execution()   (polled until SUCCEEDED)
  - athena.get_paginator("get_query_results") → paginator.paginate()

Coverage targets:
  - All four query types return 200 with results
  - Invalid query params → 422
  - date_from > date_to → 422
  - Date range > 90 days → 422
  - Athena FAILED state → 500
  - Athena timeout (simulated) → 500
  - SSM unavailable → 500
  - scanned_bytes and execution_ms present in response
  - SQL partition filter present (Glue cost guard)
"""

from __future__ import annotations

import json
import sys
import os
from unittest.mock import MagicMock, patch, call

import pytest

from conftest import SSM_VALUES, make_query_event, mock_ssm, mock_s3


# ---------------------------------------------------------------------------
# Athena mock factory
# ---------------------------------------------------------------------------

EXECUTION_ID = "aaaa-bbbb-cccc-dddd"

def _make_athena_mock(
    final_state: str = "SUCCEEDED",
    scanned_bytes: int = 4096,
    rows: list[list[str]] | None = None,
    column_names: list[str] | None = None,
):
    """
    Build a MagicMock that mimics the Athena boto3 client.

    rows     — list of value lists (excluding header)
    column_names — column labels returned in ResultSetMetadata
    """
    if rows is None:
        rows = [["page_view", "4210"], ["click", "980"]]
    if column_names is None:
        column_names = ["event_type", "event_count"]

    athena = MagicMock()

    # start_query_execution
    athena.start_query_execution.return_value = {
        "QueryExecutionId": EXECUTION_ID
    }

    # get_query_execution — always return terminal state on first poll
    athena.get_query_execution.return_value = {
        "QueryExecution": {
            "QueryExecutionId": EXECUTION_ID,
            "Status": {
                "State": final_state,
                "StateChangeReason": "Query failed." if final_state == "FAILED" else None,
            },
            "Statistics": {
                "DataScannedInBytes": scanned_bytes,
                "EngineExecutionTimeInMillis": 800,
            },
        }
    }

    # get_paginator / paginate — return one page with header + data rows
    header_row = {
        "Data": [{"VarCharValue": col} for col in column_names]
    }
    data_rows = [
        {"Data": [{"VarCharValue": val} for val in row]}
        for row in rows
    ]
    page = {
        "ResultSet": {
            "ResultSetMetadata": {
                "ColumnInfo": [{"Label": col} for col in column_names]
            },
            "Rows": [header_row] + data_rows,
        }
    }
    paginator   = MagicMock()
    paginator.paginate.return_value = iter([page])
    athena.get_paginator.return_value = paginator

    return athena


# ---------------------------------------------------------------------------
# Helper — call handler with patched clients
# ---------------------------------------------------------------------------

def _call_handler(apigw_event: dict, mock_athena, mock_ssm_client):
    for mod in list(sys.modules.keys()):
        if mod in ("handler", "models"):
            del sys.modules[mod]

    with patch("boto3.client") as mock_boto3:
        def client_factory(service, **kwargs):
            if service == "athena":
                return mock_athena
            if service == "ssm":
                return mock_ssm_client
            return MagicMock()

        mock_boto3.side_effect = client_factory
        import handler as query_handler
        return query_handler.handler(apigw_event, context=None)


# ---------------------------------------------------------------------------
# Happy path — all four query types
# ---------------------------------------------------------------------------

class TestQueryTypes:

    BASE_PARAMS = {
        "query_type": "event_count",
        "date_from":  "2026-03-01",
        "date_to":    "2026-03-09",
    }

    def test_event_count_returns_200(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 200

    def test_event_count_results_present(self, mock_ssm):
        athena = _make_athena_mock(rows=[["page_view", "100"], ["click", "50"]])
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        body   = json.loads(resp["body"])
        assert body["rows_returned"] == 2
        assert body["results"][0]["event_type"] == "page_view"

    def test_timeseries_query(self, mock_ssm):
        athena = _make_athena_mock(
            rows=[["2026-03-09 10:00:00.000", "page_view", "42"]],
            column_names=["hour", "event_type", "event_count"],
        )
        params = {**self.BASE_PARAMS, "query_type": "timeseries"}
        event  = make_query_event(params)
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 200
        body = json.loads(resp["body"])
        assert body["query_type"] == "timeseries"

    def test_top_sessions_query(self, mock_ssm):
        athena = _make_athena_mock(
            rows=[["sess_abc", "25", "2026-03-09T08:00:00Z", "2026-03-09T09:00:00Z"]],
            column_names=["session_id", "event_count", "session_start", "session_end"],
        )
        params = {**self.BASE_PARAMS, "query_type": "top_sessions", "limit": "10"}
        event  = make_query_event(params)
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 200

    def test_errors_query(self, mock_ssm):
        athena = _make_athena_mock(
            rows=[["evt-1", "2026-03-09T10:00:00Z", "sess_a", None, "{}"]],
            column_names=["event_id", "timestamp", "session_id", "user_id", "properties"],
        )
        params = {**self.BASE_PARAMS, "query_type": "errors"}
        event  = make_query_event(params)
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 200

    def test_execution_id_in_response(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        body   = json.loads(resp["body"])
        assert body["query_execution_id"] == EXECUTION_ID

    def test_scanned_bytes_in_response(self, mock_ssm):
        athena = _make_athena_mock(scanned_bytes=8192)
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        body   = json.loads(resp["body"])
        assert body["scanned_bytes"] == 8192

    def test_execution_ms_in_response(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        body   = json.loads(resp["body"])
        assert isinstance(body["execution_ms"], int)
        assert body["execution_ms"] >= 0

    def test_date_range_echoed_in_response(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        body   = json.loads(resp["body"])
        assert body["date_from"] == "2026-03-01"
        assert body["date_to"]   == "2026-03-09"

    def test_athena_submit_called_once(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        _call_handler(event, athena, mock_ssm)
        athena.start_query_execution.assert_called_once()

    def test_output_location_uses_athena_bucket(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        _call_handler(event, athena, mock_ssm)
        call_kwargs = athena.start_query_execution.call_args[1]
        expected_prefix = f"s3://{SSM_VALUES['/cloudpulse/dev/athena_output_bucket']}"
        assert call_kwargs["ResultConfiguration"]["OutputLocation"].startswith(expected_prefix)


# ---------------------------------------------------------------------------
# SQL partition filter (Glue cost guard)
# ---------------------------------------------------------------------------

class TestSQLPartitionFilter:
    """
    Ensure every generated SQL contains the Hive partition filter so
    Athena never does a full-table scan.
    """

    BASE_PARAMS = {
        "query_type": "event_count",
        "date_from":  "2026-03-01",
        "date_to":    "2026-03-09",
    }

    def _capture_sql(self, params: dict, mock_ssm_client) -> str:
        for mod in list(sys.modules.keys()):
            if mod in ("handler", "models"):
                del sys.modules[mod]

        captured = {}

        def fake_start(**kwargs):
            captured["sql"] = kwargs["QueryString"]
            return {"QueryExecutionId": EXECUTION_ID}

        athena = _make_athena_mock()
        athena.start_query_execution.side_effect = fake_start
        event = make_query_event(params)
        _call_handler(event, athena, mock_ssm_client)
        return captured.get("sql", "")

    def test_event_count_has_date_filter(self, mock_ssm):
        sql = self._capture_sql(self.BASE_PARAMS, mock_ssm)
        assert "BETWEEN" in sql
        assert "2026-03-01" in sql
        assert "2026-03-09" in sql

    def test_timeseries_has_date_filter(self, mock_ssm):
        params = {**self.BASE_PARAMS, "query_type": "timeseries"}
        sql    = self._capture_sql(params, mock_ssm)
        assert "BETWEEN" in sql

    def test_event_type_filter_injected(self, mock_ssm):
        params = {**self.BASE_PARAMS, "event_type": "click"}
        sql    = self._capture_sql(params, mock_ssm)
        assert "event_type = 'click'" in sql


# ---------------------------------------------------------------------------
# Validation errors
# ---------------------------------------------------------------------------

class TestQueryValidation:

    def test_missing_query_type_returns_422(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event({"date_from": "2026-03-01", "date_to": "2026-03-09"})
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 422

    def test_missing_dates_returns_422(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event({"query_type": "event_count"})
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 422

    def test_date_from_after_date_to_returns_422(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event({
            "query_type": "event_count",
            "date_from":  "2026-03-09",
            "date_to":    "2026-03-01",   # reversed
        })
        resp = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 422

    def test_date_range_over_90_days_returns_422(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event({
            "query_type": "event_count",
            "date_from":  "2026-01-01",
            "date_to":    "2026-12-31",   # 364 days
        })
        resp = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 422

    def test_invalid_query_type_returns_422(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event({
            "query_type": "make_me_rich",
            "date_from":  "2026-03-01",
            "date_to":    "2026-03-09",
        })
        resp = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 422

    def test_limit_above_1000_returns_422(self, mock_ssm):
        athena = _make_athena_mock()
        event  = make_query_event({
            "query_type": "top_sessions",
            "date_from":  "2026-03-01",
            "date_to":    "2026-03-09",
            "limit":      "9999",
        })
        resp = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 422


# ---------------------------------------------------------------------------
# Athena failure states
# ---------------------------------------------------------------------------

class TestAthenaFailures:

    BASE_PARAMS = {
        "query_type": "event_count",
        "date_from":  "2026-03-01",
        "date_to":    "2026-03-09",
    }

    def test_athena_failed_state_returns_500(self, mock_ssm):
        athena = _make_athena_mock(final_state="FAILED")
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 500

    def test_athena_cancelled_state_returns_500(self, mock_ssm):
        athena = _make_athena_mock(final_state="CANCELLED")
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, mock_ssm)
        assert resp["statusCode"] == 500

    def test_ssm_failure_returns_500(self, mock_s3):
        from botocore.exceptions import ClientError

        broken_ssm = MagicMock()
        broken_ssm.get_parameter.side_effect = ClientError(
            {"Error": {"Code": "ParameterNotFound", "Message": "not found"}},
            "GetParameter",
        )
        athena = _make_athena_mock()
        event  = make_query_event(self.BASE_PARAMS)
        resp   = _call_handler(event, athena, broken_ssm)
        assert resp["statusCode"] == 500


# ---------------------------------------------------------------------------
# QueryRequest model unit tests (no boto3)
# ---------------------------------------------------------------------------

class TestQueryRequestModel:

    def test_valid_request_parses(self):
        from models import QueryRequest, QueryType
        req = QueryRequest.model_validate({
            "query_type": "event_count",
            "date_from":  "2026-03-01",
            "date_to":    "2026-03-09",
        })
        assert req.query_type == QueryType.EVENT_COUNT

    def test_default_limit_is_100(self):
        from models import QueryRequest
        req = QueryRequest.model_validate({
            "query_type": "top_sessions",
            "date_from":  "2026-03-01",
            "date_to":    "2026-03-09",
        })
        assert req.limit == 100

    def test_same_day_range_valid(self):
        from models import QueryRequest
        req = QueryRequest.model_validate({
            "query_type": "errors",
            "date_from":  "2026-03-09",
            "date_to":    "2026-03-09",
        })
        assert req.date_from == req.date_to
