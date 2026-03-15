"""
cloudpulse/tests/test_worker.py

Unit tests for the Worker Lambda (SQS → S3).

Uses importlib.util to load handler.py by path so both handler.py files
(ingest and worker) can coexist in the same pytest session without
competing for the "handler" key in sys.modules.
"""

import importlib.util
import json
import pathlib
import sys
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Load the worker handler module under a unique module name
# ---------------------------------------------------------------------------

_HANDLER_PATH = (
    pathlib.Path(__file__).parent.parent
    / "lambdas" / "worker" / "handler.py"
)

spec = importlib.util.spec_from_file_location("worker_handler", str(_HANDLER_PATH))
worker_handler = importlib.util.module_from_spec(spec)
sys.modules["worker_handler"] = worker_handler
spec.loader.exec_module(worker_handler)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _make_event(records: list[dict]) -> dict:
    """Wrap a list of SQS record dicts in an SQS Lambda event envelope."""
    return {"Records": records}


def _make_sqs_record(body: dict, message_id: str = "msg-001") -> dict:
    return {
        "messageId": message_id,
        "body": json.dumps(body),
    }


def _sample_record() -> dict:
    return {
        "event_id":   "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "event_type": "page_view",
        "timestamp":  "2026-03-15T10:00:00+00:00",
        "session_id": "sess-test",
        "source":     "web",
    }


# ---------------------------------------------------------------------------
# _write_to_s3 — unit tests
# ---------------------------------------------------------------------------


class TestWriteToS3:
    def test_calls_put_object_with_correct_args(self):
        mock_s3 = MagicMock()
        with patch.object(worker_handler, "_s3", mock_s3):
            worker_handler._write_to_s3("my-bucket", "events/test.json", {"k": "v"})

        call_kwargs = mock_s3.put_object.call_args.kwargs
        assert call_kwargs["Bucket"] == "my-bucket"
        assert call_kwargs["Key"] == "events/test.json"
        assert '"k": "v"' in call_kwargs["Body"]
        assert call_kwargs["ContentType"] == "application/json"

    def test_raises_on_client_error(self):
        from botocore.exceptions import ClientError

        mock_s3 = MagicMock()
        mock_s3.put_object.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "denied"}}, "PutObject"
        )
        with patch.object(worker_handler, "_s3", mock_s3):
            with pytest.raises(ClientError):
                worker_handler._write_to_s3("bucket", "key.json", {})


# ---------------------------------------------------------------------------
# handler — integration-style unit tests
# ---------------------------------------------------------------------------


class TestHandler:
    def _mock_ssm(self, bucket: str = "test-bucket"):
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": bucket}}
        return mock_ssm

    def test_happy_path_single_record(self):
        record  = _sample_record()
        s3_key  = "events/year=2026/month=03/day=15/event_type=page_view/test.json"
        ev      = _make_event([_make_sqs_record({"s3_key": s3_key, "record": record})])

        mock_ssm = self._mock_ssm("data-lake")
        mock_s3  = MagicMock()

        with (
            patch.object(worker_handler, "_ssm", mock_ssm),
            patch.object(worker_handler, "_s3", mock_s3),
            patch.dict(worker_handler._param_cache, {}, clear=True),
        ):
            worker_handler.handler(ev, None)

        mock_s3.put_object.assert_called_once()
        args = mock_s3.put_object.call_args.kwargs
        assert args["Bucket"] == "data-lake"
        assert args["Key"] == s3_key
        assert json.loads(args["Body"])["event_id"] == record["event_id"]

    def test_multiple_records_each_written(self):
        records = [
            _make_sqs_record(
                {"s3_key": f"events/type=click/{i}.json", "record": {"event_id": str(i)}},
                message_id=f"msg-{i}",
            )
            for i in range(3)
        ]
        ev = _make_event(records)

        mock_ssm = self._mock_ssm()
        mock_s3  = MagicMock()

        with (
            patch.object(worker_handler, "_ssm", mock_ssm),
            patch.object(worker_handler, "_s3", mock_s3),
            patch.dict(worker_handler._param_cache, {}, clear=True),
        ):
            worker_handler.handler(ev, None)

        assert mock_s3.put_object.call_count == 3

    def test_malformed_body_raises(self):
        """Malformed message must raise so SQS can retry / DLQ."""
        bad_record = {"messageId": "bad-msg", "body": '{"no_s3_key": true}'}
        ev = _make_event([bad_record])

        mock_ssm = self._mock_ssm()
        mock_s3  = MagicMock()

        with (
            patch.object(worker_handler, "_ssm", mock_ssm),
            patch.object(worker_handler, "_s3", mock_s3),
            patch.dict(worker_handler._param_cache, {}, clear=True),
        ):
            with pytest.raises(KeyError):
                worker_handler.handler(ev, None)

    def test_invalid_json_body_raises(self):
        bad_record = {"messageId": "bad-json", "body": "not-json{{{"}
        ev = _make_event([bad_record])

        mock_ssm = self._mock_ssm()
        mock_s3  = MagicMock()

        with (
            patch.object(worker_handler, "_ssm", mock_ssm),
            patch.object(worker_handler, "_s3", mock_s3),
            patch.dict(worker_handler._param_cache, {}, clear=True),
        ):
            with pytest.raises(json.JSONDecodeError):
                worker_handler.handler(ev, None)

    def test_ssm_failure_returns_500(self):
        from botocore.exceptions import ClientError

        mock_ssm = MagicMock()
        mock_ssm.get_parameter.side_effect = ClientError(
            {"Error": {"Code": "ParameterNotFound", "Message": "not found"}},
            "GetParameter",
        )
        ev = _make_event([_make_sqs_record({"s3_key": "k", "record": {}})])

        with (
            patch.object(worker_handler, "_ssm", mock_ssm),
            patch.dict(worker_handler._param_cache, {}, clear=True),
        ):
            with pytest.raises(ClientError):
                worker_handler.handler(ev, None)

    def test_uses_cached_ssm_parameter(self):
        """SSM should only be called once even for 3 records (cached)."""
        records = [
            _make_sqs_record(
                {"s3_key": f"events/{i}.json", "record": {"id": i}},
                message_id=f"m{i}",
            )
            for i in range(3)
        ]
        ev = _make_event(records)

        mock_ssm = self._mock_ssm("cached-bucket")
        mock_s3  = MagicMock()
        env_key  = "/cloudpulse/dev/s3_bucket"

        with (
            patch.object(worker_handler, "_ssm", mock_ssm),
            patch.object(worker_handler, "_s3", mock_s3),
            patch.dict(worker_handler._param_cache, {env_key: "cached-bucket"}, clear=True),
        ):
            worker_handler.handler(ev, None)

        # SSM was pre-populated — should never have been called
        mock_ssm.get_parameter.assert_not_called()
        assert mock_s3.put_object.call_count == 3
