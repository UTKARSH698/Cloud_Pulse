"""
tests/conftest.py

Shared pytest fixtures for CloudPulse tests.

Strategy: use unittest.mock.patch to replace boto3 clients so tests
run instantly with no AWS credentials and no cost.
"""

from __future__ import annotations

import json
import sys
import os
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Make Lambda source directories importable without installing as packages
# ---------------------------------------------------------------------------

REPO_ROOT = os.path.dirname(os.path.dirname(__file__))
sys.path.insert(0, os.path.join(REPO_ROOT, "lambdas", "ingest"))
sys.path.insert(0, os.path.join(REPO_ROOT, "lambdas", "query"))


# ---------------------------------------------------------------------------
# Reusable event payloads
# ---------------------------------------------------------------------------

VALID_SINGLE_EVENT = {
    "event_type": "page_view",
    "session_id": "sess_abc123",
    "source":     "web",
    "properties": {"page": "/dashboard", "duration_ms": 1200},
    "metadata":   {"country": "IN", "user_agent": "Mozilla/5.0"},
}

VALID_BATCH_BODY = {
    "events": [
        {
            "event_type": "click",
            "session_id": "sess_abc123",
            "source":     "web",
            "properties": {"element": "btn-signup"},
        },
        {
            "event_type": "page_view",
            "session_id": "sess_xyz789",
            "source":     "mobile",
            "properties": {"page": "/home"},
        },
    ]
}


# ---------------------------------------------------------------------------
# API Gateway proxy event factories
# ---------------------------------------------------------------------------

def make_apigw_event(body: dict, path: str = "/events") -> dict:
    """Wrap a dict body in a minimal API Gateway proxy integration event."""
    return {
        "httpMethod":        "POST",
        "path":              path,
        "queryStringParameters": None,
        "headers":           {"Content-Type": "application/json"},
        "isBase64Encoded":   False,
        "body":              json.dumps(body),
    }


def make_query_event(params: dict) -> dict:
    """Wrap query-string params in a minimal API Gateway GET event."""
    return {
        "httpMethod":            "GET",
        "path":                  "/query",
        "queryStringParameters": params,
        "body":                  None,
        "isBase64Encoded":       False,
    }


# ---------------------------------------------------------------------------
# Shared SSM mock — returns sensible defaults for all /cloudpulse/* params
# ---------------------------------------------------------------------------

SSM_VALUES = {
    "/cloudpulse/dev/s3_bucket":           "cloudpulse-dev-events",
    "/cloudpulse/dev/s3_prefix":           "events",
    "/cloudpulse/dev/athena_output_bucket": "cloudpulse-dev-athena-output",
    "/cloudpulse/dev/glue_database":       "cloudpulse_dev",
    "/cloudpulse/dev/glue_table":          "events",
    "/cloudpulse/dev/sqs_queue_url":       "https://sqs.us-east-1.amazonaws.com/123456789012/cloudpulse-dev-events",
    "/cloudpulse/dev/kinesis_stream":      "cloudpulse-dev-events",
    "/cloudpulse/dev/dynamodb_table":      "cloudpulse-dev-metrics",
}


@pytest.fixture
def mock_ssm():
    """Patch boto3 SSM client used inside the Lambda handlers."""
    mock = MagicMock()
    mock.get_parameter.side_effect = lambda Name, **_: {
        "Parameter": {"Value": SSM_VALUES[Name]}
    }
    return mock


@pytest.fixture
def mock_s3():
    """Patch boto3 S3 client; put_object succeeds by default."""
    mock = MagicMock()
    mock.put_object.return_value = {"ResponseMetadata": {"HTTPStatusCode": 200}}
    return mock


@pytest.fixture
def mock_sqs():
    """Patch boto3 SQS client; send_message succeeds by default."""
    mock = MagicMock()
    mock.send_message.return_value = {"MessageId": "test-message-id"}
    return mock
