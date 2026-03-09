"""
cloudpulse/lambdas/ingest/models.py

Pydantic v2 data models for CloudPulse analytics events.

Design decisions:
  - Hive-style S3 partition keys so Glue Crawler auto-discovers partitions
    and Athena can prune them for cost efficiency.
  - `to_s3_record()` produces a flat, JSON-serialisable dict so each S3
    object is one self-contained NDJSON record (easy for Glue to schema).
  - Properties blob capped at 10 KB to protect S3 object sizes.
  - Batch endpoint capped at 100 events to stay within Lambda's 6 MB
    response limit and 3-second API Gateway timeout on the free tier.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Optional
from uuid import UUID, uuid4

from pydantic import BaseModel, Field, field_validator, model_validator


# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

class EventType(str, Enum):
    PAGE_VIEW    = "page_view"
    CLICK        = "click"
    API_CALL     = "api_call"
    FORM_SUBMIT  = "form_submit"
    ERROR        = "error"
    CUSTOM       = "custom"


class EventSource(str, Enum):
    WEB    = "web"
    MOBILE = "mobile"
    API    = "api"
    SERVER = "server"


# ---------------------------------------------------------------------------
# Sub-models
# ---------------------------------------------------------------------------

class EventMetadata(BaseModel):
    """HTTP / device context attached at ingestion time (all optional)."""

    ip_address: Optional[str] = Field(None, max_length=45)   # IPv4 or IPv6
    user_agent: Optional[str] = Field(None, max_length=512)
    country:    Optional[str] = Field(None, max_length=2)     # ISO 3166-1 alpha-2
    region:     Optional[str] = Field(None, max_length=64)
    referrer:   Optional[str] = Field(None, max_length=2048)


# ---------------------------------------------------------------------------
# Core event model
# ---------------------------------------------------------------------------

class AnalyticsEvent(BaseModel):
    """
    A single analytics event emitted by a client.

    Example payload
    ---------------
    {
        "event_type": "page_view",
        "session_id": "sess_abc123",
        "source": "web",
        "properties": {
            "page": "/dashboard",
            "duration_ms": 1850
        },
        "metadata": {
            "country": "IN",
            "user_agent": "Mozilla/5.0 ..."
        }
    }
    """

    event_id:   UUID     = Field(default_factory=uuid4, description="Auto-generated if omitted")
    event_type: EventType
    timestamp:  datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc),
        description="ISO-8601 UTC timestamp; defaults to server time if omitted",
    )
    session_id: str      = Field(..., min_length=1, max_length=128)
    user_id:    Optional[str] = Field(None, max_length=128)
    source:     EventSource
    properties: dict[str, Any] = Field(default_factory=dict)
    metadata:   EventMetadata  = Field(default_factory=EventMetadata)

    # -- Validators ----------------------------------------------------------

    @field_validator("timestamp", mode="before")
    @classmethod
    def parse_timestamp(cls, v: Any) -> Any:
        """Accept both ISO strings and datetime objects."""
        if isinstance(v, str):
            return datetime.fromisoformat(v.replace("Z", "+00:00"))
        return v

    @field_validator("properties")
    @classmethod
    def cap_properties_size(cls, v: dict) -> dict:
        """Reject payloads that would bloat S3 objects."""
        if len(json.dumps(v, default=str)) > 10_000:
            raise ValueError("'properties' exceeds the 10 KB limit")
        return v

    # -- S3 helpers ----------------------------------------------------------

    def s3_key(self, prefix: str = "events") -> str:
        """
        Hive-style partition key compatible with Glue Crawler.

        Pattern: {prefix}/year=YYYY/month=MM/day=DD/event_type={type}/{uuid}.json

        Glue auto-detects `year`, `month`, `day`, and `event_type` as
        partition columns — no manual `MSCK REPAIR TABLE` needed.
        """
        ts = self.timestamp
        return (
            f"{prefix}/"
            f"year={ts.year:04d}/"
            f"month={ts.month:02d}/"
            f"day={ts.day:02d}/"
            f"event_type={self.event_type.value}/"
            f"{self.event_id}.json"
        )

    def to_s3_record(self) -> dict[str, Any]:
        """
        Flat, JSON-serialisable dict written as one S3 object.

        All UUIDs and enums are converted to strings so the record is
        immediately queryable by Athena without custom SerDe.
        """
        return {
            "event_id":   str(self.event_id),
            "event_type": self.event_type.value,
            "timestamp":  self.timestamp.isoformat(),
            "year":       self.timestamp.year,
            "month":      self.timestamp.month,
            "day":        self.timestamp.day,
            "session_id": self.session_id,
            "user_id":    self.user_id,
            "source":     self.source.value,
            "properties": self.properties,
            **self.metadata.model_dump(exclude_none=True),
        }


# ---------------------------------------------------------------------------
# Request / response wrappers
# ---------------------------------------------------------------------------

class BatchIngestRequest(BaseModel):
    """Wraps up to 100 events in a single POST /events/batch call."""

    events: list[AnalyticsEvent] = Field(..., min_length=1, max_length=100)

    @model_validator(mode="after")
    def check_batch_ceiling(self) -> "BatchIngestRequest":
        if len(self.events) > 100:
            raise ValueError(f"Batch of {len(self.events)} exceeds the 100-event limit")
        return self


class IngestResult(BaseModel):
    """Structured response returned to the API Gateway caller."""

    accepted:  int
    rejected:  int
    event_ids: list[str]
    errors:    list[dict[str, str]] = Field(default_factory=list)
