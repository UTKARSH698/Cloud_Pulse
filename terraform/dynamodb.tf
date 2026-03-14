# ============================================================
# terraform/dynamodb.tf
#
# DynamoDB table for real-time metrics (speed layer).
#
# Schema
# ------
#   PK  metric   String  "events#page_view" | "sessions#active"
#   SK  minute   String  "2026-03-14T10:45"
#   count        Number  atomic ADD counter (per-event-type per minute)
#   sessions     StringSet  unique session IDs (for sessions#active rows)
#   expires_at   Number  Unix timestamp — TTL; rows expire after 24 h
#
# Why DynamoDB over ElastiCache/Redis?
# -------------------------------------
# Redis requires a running cluster (~$15/month minimum) which
# breaks the project's free-tier-first approach. DynamoDB is
# serverless, pay-per-request, and still delivers single-digit
# millisecond reads — ideal for a dashboard refreshing every 10 s.
#
# TTL on expires_at means rows auto-delete after 24 hours at no cost.
# Table never grows unboundedly even under sustained traffic.
#
# Billing mode: PAY_PER_REQUEST (on-demand)
# Zero idle cost, no capacity planning needed.
# ============================================================

resource "aws_dynamodb_table" "realtime" {
  name         = "${local.name_prefix}-realtime"
  billing_mode = "PAY_PER_REQUEST"   # serverless pricing, no provisioned capacity

  hash_key  = "metric"
  range_key = "minute"

  attribute {
    name = "metric"
    type = "S"
  }

  attribute {
    name = "minute"
    type = "S"
  }

  # TTL — DynamoDB automatically deletes items when expires_at < now
  # Items older than 24 h are cleaned up for free (no write cost for TTL deletes)
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false   # disabled for cost; enable in prod
  }

  tags = {
    Name = "${local.name_prefix}-realtime-metrics"
  }
}
