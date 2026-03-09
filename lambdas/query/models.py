"""
cloudpulse/lambdas/query/models.py

Request and response models for the CloudPulse query Lambda.

Athena works asynchronously — you submit a query, get an execution ID,
then poll until the query finishes. This Lambda hides that complexity by
polling internally (with a timeout guard) and returning results directly.

Query types exposed via the API
--------------------------------
GET /query/events/count        — total events grouped by event_type for a date range
GET /query/events/timeseries   — event counts bucketed by hour
GET /query/sessions/top        — top N sessions by event count
GET /query/errors              — error events with properties
"""

from __future__ import annotations

from datetime import date
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field, model_validator


# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

class QueryType(str, Enum):
    EVENT_COUNT  = "event_count"
    TIMESERIES   = "timeseries"
    TOP_SESSIONS = "top_sessions"
    ERRORS       = "errors"


# ---------------------------------------------------------------------------
# Request model
# ---------------------------------------------------------------------------

class QueryRequest(BaseModel):
    """
    Parameters for a pre-built analytics query.

    All queries are scoped to [date_from, date_to] inclusive.
    Athena partition pruning uses the year/month/day columns so only
    the relevant S3 folders are scanned — keeps cost near zero.
    """

    query_type: QueryType
    date_from:  date = Field(..., description="Start date inclusive (YYYY-MM-DD)")
    date_to:    date = Field(..., description="End date inclusive (YYYY-MM-DD)")
    limit:      int  = Field(default=100, ge=1, le=1000,
                             description="Max rows returned (top_sessions / errors only)")
    event_type: Optional[str] = Field(
        None,
        description="Filter by a specific event_type (all types if omitted)",
    )

    @model_validator(mode="after")
    def date_range_valid(self) -> "QueryRequest":
        if self.date_from > self.date_to:
            raise ValueError("date_from must be ≤ date_to")
        delta = (self.date_to - self.date_from).days
        if delta > 90:
            raise ValueError("Date range cannot exceed 90 days (free-tier Athena cost guard)")
        return self


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------

class AthenaRow(BaseModel):
    """One row from Athena results, represented as a flat key-value dict."""
    data: dict[str, Any]


class QueryResponse(BaseModel):
    """Structured response returned to API Gateway after Athena finishes."""

    query_type:       QueryType
    query_execution_id: str
    rows_returned:    int
    scanned_bytes:    int                   # reported by Athena — useful for cost awareness
    execution_ms:     int                   # end-to-end wall time inside Lambda
    date_from:        str
    date_to:          str
    results:          list[dict[str, Any]]
    truncated:        bool = False          # True if Athena returned more rows than `limit`
