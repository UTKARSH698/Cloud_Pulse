#!/usr/bin/env python3
"""
scripts/seed_events.py

Generates and POSTs realistic analytics events to the CloudPulse API.
Used to populate the S3 data lake so Glue and Athena have data
to work with for demo screenshots and README GIFs.

Usage
-----
# First deploy the stack and export outputs:
  cd terraform && terraform output -json > ../scripts/tf_outputs.json

# Get a Cognito token:
  TOKEN=$(aws cognito-idp initiate-auth \
    --auth-flow USER_PASSWORD_AUTH \
    --client-id <client_id> \
    --auth-parameters USERNAME=<email>,PASSWORD=<password> \
    --query 'AuthenticationResult.AccessToken' --output text)

# Seed 500 events across the last 7 days:
  python scripts/seed_events.py \
    --api-url https://<id>.execute-api.us-east-1.amazonaws.com/v1 \
    --token $TOKEN \
    --events 500 \
    --days 7

# Or load API URL + token from tf_outputs.json + env var:
  CLOUDPULSE_TOKEN=$TOKEN python scripts/seed_events.py --from-outputs
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# Realistic data pools
# ---------------------------------------------------------------------------

PAGES = [
    "/", "/dashboard", "/analytics", "/events", "/settings",
    "/profile", "/billing", "/docs", "/api-reference", "/pricing",
]

COUNTRIES = [
    ("IN", "Maharashtra"), ("US", "California"), ("US", "New York"),
    ("GB", "England"),     ("DE", "Bavaria"),    ("SG", None),
    ("AU", "New South Wales"), ("CA", "Ontario"), ("FR", "Île-de-France"),
    ("JP", None),
]

USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/121.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1",
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/121.0",
    "CloudPulse-SDK/1.0 Python/3.11",
]

SOURCES       = ["web", "mobile", "api"]
SOURCE_WEIGHTS = [0.60, 0.30, 0.10]

ERROR_MESSAGES = [
    ("RateLimitExceeded", "429"),
    ("UnauthorizedAccess", "401"),
    ("ResourceNotFound",   "404"),
    ("InternalServerError","500"),
    ("ValidationFailed",   "422"),
]

BUTTON_ELEMENTS = [
    "btn-signup", "btn-login", "btn-upgrade", "btn-export",
    "btn-delete", "nav-dashboard", "nav-docs", "tab-overview",
]

API_ENDPOINTS = [
    "/api/v1/events", "/api/v1/query", "/api/v1/sessions",
    "/api/v1/users/me", "/api/v1/metrics",
]

# ---------------------------------------------------------------------------
# Event generators — one per event_type
# ---------------------------------------------------------------------------

def _geo() -> tuple[str | None, str | None]:
    country, region = random.choice(COUNTRIES)
    return country, region


def make_page_view(session_id: str, user_id: str | None, ts: datetime) -> dict:
    country, region = _geo()
    return {
        "event_type": "page_view",
        "session_id": session_id,
        "user_id":    user_id,
        "source":     random.choices(SOURCES, SOURCE_WEIGHTS)[0],
        "timestamp":  ts.isoformat(),
        "properties": {
            "page":        random.choice(PAGES),
            "duration_ms": random.randint(200, 8000),
            "referrer":    random.choice(["google.com", "direct", "twitter.com", None]),
        },
        "metadata": {
            "country":    country,
            "region":     region,
            "user_agent": random.choice(USER_AGENTS),
        },
    }


def make_click(session_id: str, user_id: str | None, ts: datetime) -> dict:
    country, region = _geo()
    return {
        "event_type": "click",
        "session_id": session_id,
        "user_id":    user_id,
        "source":     "web",
        "timestamp":  ts.isoformat(),
        "properties": {
            "element":  random.choice(BUTTON_ELEMENTS),
            "page":     random.choice(PAGES),
            "x":        random.randint(0, 1920),
            "y":        random.randint(0, 1080),
        },
        "metadata": {
            "country":    country,
            "region":     region,
            "user_agent": random.choice(USER_AGENTS),
        },
    }


def make_api_call(session_id: str, user_id: str | None, ts: datetime) -> dict:
    return {
        "event_type": "api_call",
        "session_id": session_id,
        "user_id":    user_id,
        "source":     "api",
        "timestamp":  ts.isoformat(),
        "properties": {
            "endpoint":       random.choice(API_ENDPOINTS),
            "method":         random.choice(["GET", "POST", "DELETE"]),
            "status_code":    random.choice([200, 200, 200, 201, 400, 422, 429]),
            "latency_ms":     random.randint(15, 500),
        },
        "metadata": {},
    }


def make_form_submit(session_id: str, user_id: str | None, ts: datetime) -> dict:
    country, region = _geo()
    return {
        "event_type": "form_submit",
        "session_id": session_id,
        "user_id":    user_id,
        "source":     random.choices(SOURCES, SOURCE_WEIGHTS)[0],
        "timestamp":  ts.isoformat(),
        "properties": {
            "form":     random.choice(["signup", "login", "contact", "feedback"]),
            "success":  random.choice([True, True, True, False]),
            "fields":   random.randint(2, 8),
        },
        "metadata": {
            "country": country,
            "region":  region,
        },
    }


def make_error(session_id: str, user_id: str | None, ts: datetime) -> dict:
    country, region = _geo()
    msg, code = random.choice(ERROR_MESSAGES)
    return {
        "event_type": "error",
        "session_id": session_id,
        "user_id":    user_id,
        "source":     random.choices(SOURCES, SOURCE_WEIGHTS)[0],
        "timestamp":  ts.isoformat(),
        "properties": {
            "message": msg,
            "code":    code,
            "page":    random.choice(PAGES),
        },
        "metadata": {
            "country":    country,
            "region":     region,
            "user_agent": random.choice(USER_AGENTS),
        },
    }


# Distribution: page_view and click are most common
EVENT_MAKERS = [
    (make_page_view,  0.40),
    (make_click,      0.30),
    (make_api_call,   0.15),
    (make_form_submit,0.10),
    (make_error,      0.05),
]
_EVENT_FNS, _EVENT_WEIGHTS = zip(*EVENT_MAKERS)


def generate_event(session_id: str, user_id: str | None, ts: datetime) -> dict:
    maker = random.choices(_EVENT_FNS, _EVENT_WEIGHTS)[0]
    return maker(session_id, user_id, ts)


# ---------------------------------------------------------------------------
# Session simulator — a session is a burst of events from one user
# ---------------------------------------------------------------------------

def generate_session(days_ago_range: tuple[int, int]) -> list[dict]:
    """Generate 2–12 events for a single session spread over a few minutes."""
    session_id = f"sess_{uuid.uuid4().hex[:12]}"
    user_id    = f"user_{uuid.uuid4().hex[:8]}" if random.random() > 0.3 else None

    days_ago   = random.uniform(*days_ago_range)
    session_start = datetime.now(timezone.utc) - timedelta(days=days_ago)

    n_events = random.randint(2, 12)
    events   = []
    current_ts = session_start

    for _ in range(n_events):
        events.append(generate_event(session_id, user_id, current_ts))
        current_ts += timedelta(seconds=random.randint(5, 120))

    return events


# ---------------------------------------------------------------------------
# HTTP helper — no third-party deps (uses stdlib urllib)
# ---------------------------------------------------------------------------

def post_batch(api_url: str, token: str, events: list[dict]) -> tuple[int, dict]:
    """POST a batch of events; return (http_status, response_body)."""
    payload = json.dumps({"events": events}, default=str).encode()
    req = urllib.request.Request(
        url=f"{api_url.rstrip('/')}/events/batch",
        data=payload,
        headers={
            "Authorization":  f"Bearer {token}",
            "Content-Type":   "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        body = json.loads(exc.read()) if exc.fp else {}
        return exc.code, body


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Seed CloudPulse with realistic analytics events"
    )
    p.add_argument("--api-url",       help="API Gateway base URL (e.g. https://xxx.execute-api.us-east-1.amazonaws.com/v1)")
    p.add_argument("--token",         help="Cognito access token (or set CLOUDPULSE_TOKEN env var)")
    p.add_argument("--events",        type=int, default=200, help="Total events to generate (default 200)")
    p.add_argument("--days",          type=int, default=7,   help="Spread events over last N days (default 7)")
    p.add_argument("--batch-size",    type=int, default=25,  help="Events per API call (max 100, default 25)")
    p.add_argument("--from-outputs",  action="store_true",   help="Load api-url from terraform/tf_outputs.json")
    p.add_argument("--dry-run",       action="store_true",   help="Generate events but do not POST them")
    return p.parse_args()


def load_from_outputs(outputs_path: str = "scripts/tf_outputs.json") -> str:
    try:
        with open(outputs_path) as f:
            outputs = json.load(f)
        return outputs["api_endpoint"]["value"]
    except (FileNotFoundError, KeyError) as exc:
        print(f"ERROR: Could not read API URL from {outputs_path}: {exc}")
        print("Run: cd terraform && terraform output -json > ../scripts/tf_outputs.json")
        sys.exit(1)


def main() -> None:
    args  = parse_args()
    token = args.token or os.environ.get("CLOUDPULSE_TOKEN")
    api_url = args.api_url

    if args.from_outputs:
        api_url = load_from_outputs()

    if not args.dry_run:
        if not api_url:
            print("ERROR: --api-url is required (or use --from-outputs)")
            sys.exit(1)
        if not token:
            print("ERROR: --token or CLOUDPULSE_TOKEN env var is required")
            sys.exit(1)

    print(f"CloudPulse Event Seeder")
    print(f"  Target    : {api_url or '(dry-run)'}")
    print(f"  Events    : {args.events}")
    print(f"  Days span : last {args.days} days")
    print(f"  Batch size: {args.batch_size}")
    print(f"  Dry run   : {args.dry_run}")
    print()

    # Generate all events in sessions
    all_events: list[dict] = []
    days_range = (0, args.days)

    while len(all_events) < args.events:
        session_events = generate_session(days_range)
        all_events.extend(session_events)

    all_events = all_events[:args.events]
    print(f"Generated {len(all_events)} events across ~{len(all_events)//7} sessions")

    if args.dry_run:
        print("\nDry-run sample (first 3 events):")
        for e in all_events[:3]:
            print(json.dumps(e, indent=2, default=str))
        print(f"\n... and {len(all_events) - 3} more.")
        return

    # POST in batches
    total_accepted = 0
    total_rejected = 0
    batch_num      = 0
    start          = time.monotonic()

    for i in range(0, len(all_events), args.batch_size):
        batch     = all_events[i : i + args.batch_size]
        batch_num += 1

        status, body = post_batch(api_url, token, batch)

        accepted = body.get("accepted", 0)
        rejected = body.get("rejected", 0)
        total_accepted += accepted
        total_rejected += rejected

        icon = "✓" if status in (200, 207) else "✗"
        print(f"  Batch {batch_num:>3} [{i+1:>4}–{i+len(batch):>4}]  "
              f"HTTP {status}  accepted={accepted}  rejected={rejected}  {icon}")

        if status not in (200, 207):
            print(f"           Error body: {body}")

        # Small delay to stay within throttle (10 req/s usage plan)
        time.sleep(0.15)

    elapsed = time.monotonic() - start
    print()
    print(f"Done in {elapsed:.1f}s")
    print(f"  Total accepted : {total_accepted}")
    print(f"  Total rejected : {total_rejected}")
    print()
    print("Next steps:")
    print("  1. aws glue start-crawler --name cloudpulse-dev-crawler")
    print("  2. Wait ~2 min for crawler to finish")
    print(f"  3. curl '{api_url}/query?query_type=event_count"
          f"&date_from=$(date +%Y-%m-%d)&date_to=$(date +%Y-%m-%d)' \\")
    print( "       -H 'Authorization: Bearer <token>'")


if __name__ == "__main__":
    main()
