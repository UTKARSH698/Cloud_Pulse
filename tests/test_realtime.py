"""
Unit tests for lambdas/realtime/handler.py

All DynamoDB and SSM calls are mocked — no real AWS credentials needed.
"""
import importlib.util
import json
import os
import sys
from unittest.mock import MagicMock, patch

import pytest
from boto3.dynamodb.conditions import Key

# ── import handler by file path to avoid sys.modules collision with other
# handler.py files (stream_processor/handler.py has the same module name) ─────
_HANDLER_PATH = os.path.join(
    os.path.dirname(__file__), "..", "lambdas", "realtime", "handler.py"
)
_spec = importlib.util.spec_from_file_location("realtime_handler", _HANDLER_PATH)
realtime_handler = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(realtime_handler)


# ── _recent_minutes ──────────────────────────────────────────────────────────

class TestRecentMinutes:
    def test_returns_n_items(self):
        minutes = realtime_handler._recent_minutes(5)
        assert len(minutes) == 5

    def test_first_item_is_most_recent(self):
        minutes = realtime_handler._recent_minutes(3)
        # All have the same format
        for m in minutes:
            assert len(m) == 16  # "YYYY-MM-DDTHH:MM"
        # Descending order: first > second > third
        assert minutes[0] >= minutes[1] >= minutes[2]


# ── handler ──────────────────────────────────────────────────────────────────

def _make_mock_env(table_items_by_pk: dict):
    """
    Returns a mocked DynamoDB table that returns `table_items_by_pk[pk]`
    for each query call where Key('metric').eq(pk).
    """
    table = MagicMock()

    def mock_query(KeyConditionExpression, **kwargs):
        # Extract pk from the condition expression's children
        # boto3 condition expressions store the value in ._values
        try:
            pk_value = KeyConditionExpression._values[0]._values[1]
        except (AttributeError, IndexError):
            pk_value = None
        items = table_items_by_pk.get(pk_value, [])
        return {"Items": items}

    table.query.side_effect = mock_query
    return table


class TestHandler:
    def _run(self, table_items_by_pk: dict) -> dict:
        table = _make_mock_env(table_items_by_pk)

        mock_dynamodb = MagicMock()
        mock_dynamodb.Table.return_value = table
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(realtime_handler, "_dynamodb", mock_dynamodb),
            patch.object(realtime_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            raw = realtime_handler.handler({}, None)

        return json.loads(raw["body"])

    def test_returns_200(self):
        mock_dynamodb = MagicMock()
        mock_dynamodb.Table.return_value = MagicMock(
            query=MagicMock(return_value={"Items": []})
        )
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(realtime_handler, "_dynamodb", mock_dynamodb),
            patch.object(realtime_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            response = realtime_handler.handler({}, None)

        assert response["statusCode"] == 200

    def test_empty_state_returns_zeros(self):
        mock_dynamodb = MagicMock()
        mock_dynamodb.Table.return_value = MagicMock(
            query=MagicMock(return_value={"Items": []})
        )
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(realtime_handler, "_dynamodb", mock_dynamodb),
            patch.object(realtime_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            response = realtime_handler.handler({}, None)

        body = json.loads(response["body"])
        assert body["total_events"] == 0
        assert body["error_count"] == 0
        assert body["error_rate_pct"] == 0.0
        assert body["active_sessions"] == 0

    def test_response_has_required_keys(self):
        mock_dynamodb = MagicMock()
        mock_dynamodb.Table.return_value = MagicMock(
            query=MagicMock(return_value={"Items": []})
        )
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(realtime_handler, "_dynamodb", mock_dynamodb),
            patch.object(realtime_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            response = realtime_handler.handler({}, None)

        body = json.loads(response["body"])
        assert "lookback_minutes" in body
        assert "total_events" in body
        assert "error_count" in body
        assert "error_rate_pct" in body
        assert "active_sessions" in body
        assert "by_event_type" in body
        assert "timeline" in body

    def test_error_rate_computed_correctly(self):
        """8 page_views + 2 errors = 10 total → error_rate_pct = 20.0"""
        # _EVENT_TYPES order: page_view, click, api_call, form_submit, error, custom
        # Handler queries each event type in order, then sessions#active
        call_responses = [
            {"Items": [{"minute": "2026-03-14T10:45", "count": 8}]},  # page_view
            {"Items": []},  # click
            {"Items": []},  # api_call
            {"Items": []},  # form_submit
            {"Items": [{"minute": "2026-03-14T10:45", "count": 2}]},  # error
            {"Items": []},  # custom
            {"Items": []},  # sessions#active
        ]

        table = MagicMock()
        table.query.side_effect = call_responses

        mock_dynamodb = MagicMock()
        mock_dynamodb.Table.return_value = table
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(realtime_handler, "_dynamodb", mock_dynamodb),
            patch.object(realtime_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            response = realtime_handler.handler({}, None)

        body = json.loads(response["body"])
        assert body["total_events"] == 10
        assert body["error_count"] == 2
        assert body["error_rate_pct"] == 20.0

    def test_ssm_failure_returns_500(self):
        from botocore.exceptions import ClientError
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.side_effect = ClientError(
            {"Error": {"Code": "ParameterNotFound"}}, "GetParameter"
        )
        mock_dynamodb = MagicMock()
        # Clear cache so the SSM call is actually made
        realtime_handler._param_cache.clear()

        with (
            patch.object(realtime_handler, "_dynamodb", mock_dynamodb),
            patch.object(realtime_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            response = realtime_handler.handler({}, None)

        assert response["statusCode"] == 500
