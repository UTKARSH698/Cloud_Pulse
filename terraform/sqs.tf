# ============================================================
# terraform/sqs.tf
#
# SQS queue for decoupling ingest from S3 writes.
#
# Flow
# ----
#   Ingest Lambda  →  events queue  →  Worker Lambda  →  S3
#
# Why SQS between Lambda and S3?
# --------------------------------
# Ingest Lambda is API-bound (3 s timeout, in-process with the
# HTTP response). Moving the S3 write to an async worker means:
#   - API latency drops: callers see 200 once the message is
#     enqueued, not after the S3 round-trip completes.
#   - S3 transient errors retry automatically via SQS visibility
#     timeout, not by failing the API call.
#   - Worker throughput can scale independently of API concurrency.
#
# Dead-letter Queue (DLQ)
# -----------------------
# After 3 failed delivery attempts, messages move to the DLQ.
# The CloudWatch alarm fires when DLQ depth > 0 so failures are
# never silently dropped.
#
# Queue type: Standard (not FIFO)
# --------------------------------
# At-least-once delivery is fine for analytics events — S3 object
# keys are content-addressed (UUID per event) so a duplicate write
# is idempotent.
# ============================================================

# ------------------------------------------------------------
# Dead-letter queue — catches messages after 3 failed attempts
# ------------------------------------------------------------

resource "aws_sqs_queue" "events_dlq" {
  name                      = "${local.name_prefix}-events-dlq"
  message_retention_seconds = 1209600   # 14 days — maximum time to investigate

  tags = {
    Name = "${local.name_prefix}-events-dlq"
  }
}

# ------------------------------------------------------------
# Main events queue — ingest Lambda enqueues here
# ------------------------------------------------------------

resource "aws_sqs_queue" "events" {
  name                       = "${local.name_prefix}-events"
  visibility_timeout_seconds = 30      # must be >= worker Lambda timeout
  message_retention_seconds  = 345600  # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 3   # retry 3 times before sending to DLQ
  })

  tags = {
    Name = "${local.name_prefix}-events-queue"
  }
}
