"""
Unit tests for lambdas/stream_processor/handler.py

Uses moto to mock DynamoDB and MagicMock for SSM.
No real AWS credentials needed.
"""
import base64
import json
import os
import sys
import time
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import importlib.util
import pytest

# ── import handler by file path to avoid sys.modules collision with other
# handler.py files (realtime/handler.py has the same module name) ─────────────
_HANDLER_PATH = os.path.join(
    os.path.dirname(__file__), "..", "lambdas", "stream_processor", "handler.py"
)
_spec = importlib.util.spec_from_file_location("stream_processor_handler", _HANDLER_PATH)
stream_handler = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(stream_handler)


# ── helpers ──────────────────────────────────────────────────────────────────

def _make_kinesis_record(payload: dict) -> dict:
    """Wrap a dict as a Kinesis stream record (base64-encoded data)."""
    data = base64.b64encode(json.dumps(payload).encode()).decode()
    return {
        "kinesis": {
            "data": data,
            "sequenceNumber": "49590338271490256608559692540925702759324208523137515522",
            "approximateArrivalTimestamp": 1545084650.987,
        },
        "eventSource": "aws:kinesis",
    }


def _make_kinesis_event(payloads: list[dict]) -> dict:
    return {"Records": [_make_kinesis_record(p) for p in payloads]}


# ── _minute_bucket ───────────────────────────────────────────────────────────

class TestMinuteBucket:
    def test_truncates_to_minute(self):
        result = stream_handler._minute_bucket("2026-03-14T10:45:32.123Z")
        assert result == "2026-03-14T10:45"

    def test_handles_offset(self):
        result = stream_handler._minute_bucket("2026-03-14T10:45:00+00:00")
        assert result == "2026-03-14T10:45"

    def test_fallback_on_invalid(self):
        # Should not raise — returns current minute
        result = stream_handler._minute_bucket("not-a-timestamp")
        assert len(result) == 16  # "YYYY-MM-DDTHH:MM"


# ── _process_record ──────────────────────────────────────────────────────────

class TestProcessRecord:
    def test_increments_event_type_counter(self):
        table = MagicMock()
        record = _make_kinesis_record({
            "event_type": "page_view",
            "session_id": "sess_abc",
            "timestamp": "2026-03-14T10:45:00Z",
        })
        stream_handler._process_record(table, record)

        calls = [c for c in table.update_item.call_args_list]
        # First call should be for events#page_view
        first_call_key = calls[0].kwargs["Key"]
        assert first_call_key["metric"] == "events#page_view"
        assert first_call_key["minute"] == "2026-03-14T10:45"

    def test_tracks_session(self):
        table = MagicMock()
        record = _make_kinesis_record({
            "event_type": "click",
            "session_id": "sess_xyz",
            "timestamp": "2026-03-14T10:45:00Z",
        })
        stream_handler._process_record(table, record)

        # Second call should be for sessions#active
        second_call_key = table.update_item.call_args_list[1].kwargs["Key"]
        assert second_call_key["metric"] == "sessions#active"

    def test_no_session_call_when_session_id_empty(self):
        table = MagicMock()
        record = _make_kinesis_record({
            "event_type": "api_call",
            "session_id": "",
            "timestamp": "2026-03-14T10:45:00Z",
        })
        stream_handler._process_record(table, record)
        # Only 1 update_item call (events counter), no sessions call
        assert table.update_item.call_count == 1

    def test_ttl_set_to_24h_from_now(self):
        table = MagicMock()
        before = int(time.time())
        record = _make_kinesis_record({
            "event_type": "error",
            "session_id": "sess_1",
            "timestamp": "2026-03-14T10:45:00Z",
        })
        stream_handler._process_record(table, record)
        after = int(time.time())

        ttl_value = table.update_item.call_args_list[0].kwargs["ExpressionAttributeValues"][":ttl"]
        assert before + 86400 <= ttl_value <= after + 86400


# ── handler ──────────────────────────────────────────────────────────────────

class TestHandler:
    def test_processes_batch_of_records(self):
        payloads = [
            {"event_type": "page_view", "session_id": f"sess_{i}", "timestamp": "2026-03-14T10:45:00Z"}
            for i in range(3)
        ]
        kinesis_event = _make_kinesis_event(payloads)

        mock_table = MagicMock()
        mock_dynamodb = MagicMock()
        mock_dynamodb.Table.return_value = mock_table
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(stream_handler, "_dynamodb", mock_dynamodb),
            patch.object(stream_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            result = stream_handler.handler(kinesis_event, None)

        assert result["processed"] == 3
        assert result["failed"] == 0

    def test_handles_malformed_record_gracefully(self):
        # Bad base64 data
        bad_record = {"kinesis": {"data": "!!!not_base64!!!"}}
        kinesis_event = {"Records": [bad_record]}

        mock_dynamodb = MagicMock()
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "test-table"}}

        with (
            patch.object(stream_handler, "_dynamodb", mock_dynamodb),
            patch.object(stream_handler, "_ssm", mock_ssm),
            patch.dict(os.environ, {"ENVIRONMENT": "test"}),
        ):
            result = stream_handler.handler(kinesis_event, None)

        assert result["failed"] == 1
        assert result["processed"] == 0
