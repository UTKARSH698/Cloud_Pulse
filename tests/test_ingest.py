"""
tests/test_ingest.py

Unit tests for the ingest Lambda (lambdas/ingest/handler.py).

Every test patches _s3 and _ssm so no real AWS calls are made.
Coverage targets:
  - Happy path: single event, batch event
  - Validation errors: bad JSON, schema violations, oversized properties
  - S3 partial failure → HTTP 207
  - SSM unavailable → HTTP 500
  - S3 key format (partition structure for Glue)
"""

from __future__ import annotations

import json
import sys
import os
from unittest.mock import MagicMock, patch
from datetime import datetime, timezone

import pytest

# conftest.py adds lambdas/ingest to sys.path
from conftest import (
    VALID_SINGLE_EVENT,
    VALID_BATCH_BODY,
    SSM_VALUES,
    make_apigw_event,
    mock_ssm,
    mock_s3,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _call_handler(apigw_event: dict, mock_s3_client, mock_ssm_client):
    """
    Import handler fresh each call so module-level _param_cache
    doesn't bleed between tests.
    """
    # Clear cached module to reset _param_cache
    for mod in list(sys.modules.keys()):
        if mod in ("handler", "models"):
            del sys.modules[mod]

    with patch("boto3.client") as mock_boto3:
        def client_factory(service, **kwargs):
            if service == "s3":
                return mock_s3_client
            if service == "ssm":
                return mock_ssm_client
            return MagicMock()

        mock_boto3.side_effect = client_factory
        import handler
        return handler.handler(apigw_event, context=None)


# ---------------------------------------------------------------------------
# Happy path — single event
# ---------------------------------------------------------------------------

class TestSingleEventIngest:

    def test_returns_200(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_SINGLE_EVENT)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 200

    def test_accepted_count_is_one(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_SINGLE_EVENT)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        body  = json.loads(resp["body"])
        assert body["accepted"] == 1
        assert body["rejected"] == 0

    def test_event_id_returned(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_SINGLE_EVENT)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        body  = json.loads(resp["body"])
        assert len(body["event_ids"]) == 1

    def test_s3_put_called_once(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_SINGLE_EVENT)
        _call_handler(event, mock_s3, mock_ssm)
        mock_s3.put_object.assert_called_once()

    def test_s3_bucket_correct(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_SINGLE_EVENT)
        _call_handler(event, mock_s3, mock_ssm)
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == SSM_VALUES["/cloudpulse/dev/s3_bucket"]

    def test_s3_key_hive_partitioned(self, mock_s3, mock_ssm):
        """Key must follow events/year=.../month=.../day=.../event_type=.../<uuid>.json"""
        event = make_apigw_event(VALID_SINGLE_EVENT)
        _call_handler(event, mock_s3, mock_ssm)
        key = mock_s3.put_object.call_args[1]["Key"]
        assert key.startswith("events/year=")
        assert "/month=" in key
        assert "/day="   in key
        assert "/event_type=page_view/" in key
        assert key.endswith(".json")

    def test_cors_header_present(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_SINGLE_EVENT)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["headers"]["Access-Control-Allow-Origin"] == "*"


# ---------------------------------------------------------------------------
# Happy path — batch event
# ---------------------------------------------------------------------------

class TestBatchEventIngest:

    def test_batch_returns_200(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_BATCH_BODY, path="/events/batch")
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 200

    def test_batch_accepted_count(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_BATCH_BODY, path="/events/batch")
        resp  = _call_handler(event, mock_s3, mock_ssm)
        body  = json.loads(resp["body"])
        assert body["accepted"] == len(VALID_BATCH_BODY["events"])
        assert body["rejected"] == 0

    def test_batch_s3_put_called_per_event(self, mock_s3, mock_ssm):
        event = make_apigw_event(VALID_BATCH_BODY, path="/events/batch")
        _call_handler(event, mock_s3, mock_ssm)
        assert mock_s3.put_object.call_count == len(VALID_BATCH_BODY["events"])

    def test_batch_detected_by_events_key(self, mock_s3, mock_ssm):
        """Batch mode should also trigger if body contains 'events' key, even without /batch path."""
        event = make_apigw_event(VALID_BATCH_BODY, path="/events")
        resp  = _call_handler(event, mock_s3, mock_ssm)
        body  = json.loads(resp["body"])
        assert body["accepted"] == 2


# ---------------------------------------------------------------------------
# Validation errors
# ---------------------------------------------------------------------------

class TestValidationErrors:

    def test_bad_json_returns_400(self, mock_s3, mock_ssm):
        for mod in list(sys.modules.keys()):
            if mod in ("handler", "models"):
                del sys.modules[mod]

        with patch("boto3.client") as mock_boto3:
            mock_boto3.side_effect = lambda svc, **kw: mock_ssm if svc == "ssm" else mock_s3
            import handler
            raw_event = {
                "httpMethod": "POST",
                "path": "/events",
                "queryStringParameters": None,
                "isBase64Encoded": False,
                "body": "{ this is not json",
            }
            resp = handler.handler(raw_event, None)
        assert resp["statusCode"] == 400
        assert "JSON" in json.loads(resp["body"])["error"]

    def test_missing_required_field_returns_422(self, mock_s3, mock_ssm):
        bad_event = {"event_type": "page_view"}   # missing session_id and source
        event = make_apigw_event(bad_event)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 422
        body = json.loads(resp["body"])
        assert "details" in body

    def test_invalid_event_type_returns_422(self, mock_s3, mock_ssm):
        bad = {**VALID_SINGLE_EVENT, "event_type": "not_a_real_type"}
        event = make_apigw_event(bad)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 422

    def test_invalid_source_returns_422(self, mock_s3, mock_ssm):
        bad = {**VALID_SINGLE_EVENT, "source": "fax_machine"}
        event = make_apigw_event(bad)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 422

    def test_oversized_properties_returns_422(self, mock_s3, mock_ssm):
        """properties blob > 10 KB should be rejected at validation time."""
        giant = {**VALID_SINGLE_EVENT, "properties": {"data": "x" * 11_000}}
        event = make_apigw_event(giant)
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 422

    def test_batch_exceeding_100_events_returns_422(self, mock_s3, mock_ssm):
        many_events = [
            {"event_type": "click", "session_id": f"s{i}", "source": "web"}
            for i in range(101)
        ]
        event = make_apigw_event({"events": many_events}, path="/events/batch")
        resp  = _call_handler(event, mock_s3, mock_ssm)
        assert resp["statusCode"] == 422


# ---------------------------------------------------------------------------
# Partial S3 failure → HTTP 207
# ---------------------------------------------------------------------------

class TestPartialFailure:

    def test_207_on_s3_error(self, mock_ssm):
        """If S3 raises for the first event, accepted=0 rejected=1 and status=207."""
        from botocore.exceptions import ClientError

        failing_s3 = MagicMock()
        failing_s3.put_object.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "Access Denied"}},
            "PutObject",
        )
        event = make_apigw_event(VALID_SINGLE_EVENT)
        resp  = _call_handler(event, failing_s3, mock_ssm)
        assert resp["statusCode"] == 207
        body = json.loads(resp["body"])
        assert body["rejected"] == 1
        assert body["accepted"] == 0

    def test_207_partial_batch(self, mock_ssm):
        """First S3 call succeeds, second fails → 207 with 1 accepted 1 rejected."""
        from botocore.exceptions import ClientError

        call_count = {"n": 0}
        partial_s3 = MagicMock()

        def side_effect(**kwargs):
            call_count["n"] += 1
            if call_count["n"] == 2:
                raise ClientError(
                    {"Error": {"Code": "InternalError", "Message": "oops"}},
                    "PutObject",
                )
            return {}

        partial_s3.put_object.side_effect = side_effect
        event = make_apigw_event(VALID_BATCH_BODY, path="/events/batch")
        resp  = _call_handler(event, partial_s3, mock_ssm)
        assert resp["statusCode"] == 207
        body = json.loads(resp["body"])
        assert body["accepted"] == 1
        assert body["rejected"] == 1


# ---------------------------------------------------------------------------
# SSM unavailable → HTTP 500
# ---------------------------------------------------------------------------

class TestSSMFailure:

    def test_500_when_ssm_fails(self, mock_s3):
        from botocore.exceptions import ClientError

        broken_ssm = MagicMock()
        broken_ssm.get_parameter.side_effect = ClientError(
            {"Error": {"Code": "ParameterNotFound", "Message": "not found"}},
            "GetParameter",
        )
        event = make_apigw_event(VALID_SINGLE_EVENT)
        resp  = _call_handler(event, mock_s3, broken_ssm)
        assert resp["statusCode"] == 500
        assert "configuration" in json.loads(resp["body"])["error"].lower()


# ---------------------------------------------------------------------------
# Model unit tests (no Lambda / boto3 involved)
# ---------------------------------------------------------------------------

class TestAnalyticsEventModel:

    def test_event_id_auto_generated(self):
        from models import AnalyticsEvent
        e = AnalyticsEvent.model_validate(VALID_SINGLE_EVENT)
        assert e.event_id is not None

    def test_timestamp_defaults_to_utc_now(self):
        from models import AnalyticsEvent
        before = datetime.now(timezone.utc)
        e = AnalyticsEvent.model_validate(VALID_SINGLE_EVENT)
        after  = datetime.now(timezone.utc)
        assert before <= e.timestamp <= after

    def test_iso_string_timestamp_parsed(self):
        from models import AnalyticsEvent
        payload = {**VALID_SINGLE_EVENT, "timestamp": "2026-03-09T10:30:00Z"}
        e = AnalyticsEvent.model_validate(payload)
        assert e.timestamp.year  == 2026
        assert e.timestamp.month == 3
        assert e.timestamp.day   == 9

    def test_s3_key_contains_event_type_partition(self):
        from models import AnalyticsEvent
        e   = AnalyticsEvent.model_validate(VALID_SINGLE_EVENT)
        key = e.s3_key()
        assert "event_type=page_view" in key

    def test_to_s3_record_all_strings(self):
        """UUIDs and enums must be strings in the S3 record for Athena compatibility."""
        from models import AnalyticsEvent
        e      = AnalyticsEvent.model_validate(VALID_SINGLE_EVENT)
        record = e.to_s3_record()
        assert isinstance(record["event_id"],  str)
        assert isinstance(record["event_type"], str)
        assert isinstance(record["source"],     str)
