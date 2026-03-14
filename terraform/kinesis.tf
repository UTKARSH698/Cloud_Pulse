# ============================================================
# terraform/kinesis.tf
#
# Kinesis Data Stream — speed layer for real-time analytics.
#
# Architecture role
# -----------------
# Ingest Lambda dual-writes events to both S3 (batch path) and
# this stream (speed path). The stream fans out to:
#   1. Stream Processor Lambda — aggregates per-minute metrics
#      into DynamoDB for the real-time dashboard.
#   2. Kinesis Firehose — backs up all stream records to S3
#      as a redundant store (secondary to direct S3 write).
#
# Why 1 shard?
#   1 shard = 1,000 events/s write + 2 MB/s read.
#   Sufficient for demo traffic. Add shards via shard_count
#   or enable on-demand mode when traffic grows.
#
# Retention: 24 hours (free tier) — events can be replayed
# for up to 24 h if the stream processor falls behind or needs
# to reprocess records after a bug fix.
# ============================================================

resource "aws_kinesis_stream" "events" {
  name             = "${local.name_prefix}-events"
  shard_count      = 1
  retention_period = 24   # hours — minimum (free tier)

  stream_mode_details {
    stream_mode = "PROVISIONED"   # explicit shard count; switch to ON_DEMAND for auto-scaling
  }

  tags = {
    Name = "${local.name_prefix}-events-stream"
  }
}

# ============================================================
# Kinesis Firehose — stream → S3 backup
#
# Buffers stream records and writes them to S3 in batches.
# Acts as a redundant backup path alongside the direct S3
# writes from the ingest Lambda.
#
# Buffer: 5 MB or 300 s (whichever comes first) — free tier
# compliant (minimum Firehose buffer sizes).
# ============================================================

resource "aws_iam_role" "firehose" {
  name               = "${local.name_prefix}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    sid     = "FirehoseAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "firehose_s3" {
  statement {
    sid    = "FirehoseWriteBackup"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
    ]
    resources = [
      aws_s3_bucket.data_lake.arn,
      "${aws_s3_bucket.data_lake.arn}/stream-backup/*",
    ]
  }

  statement {
    sid    = "FirehoseReadStream"
    effect = "Allow"
    actions = [
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:DescribeStream",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.events.arn]
  }
}

resource "aws_iam_policy" "firehose_s3" {
  name   = "${local.name_prefix}-firehose-s3"
  policy = data.aws_iam_policy_document.firehose_s3.json
}

resource "aws_iam_role_policy_attachment" "firehose_s3" {
  role       = aws_iam_role.firehose.name
  policy_arn = aws_iam_policy.firehose_s3.arn
}

resource "aws_kinesis_firehose_delivery_stream" "backup" {
  name        = "${local.name_prefix}-stream-backup"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.events.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.data_lake.arn
    prefix     = "stream-backup/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "stream-backup-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/"

    buffering_size     = 5    # MB
    buffering_interval = 300  # seconds

    compression_format = "GZIP"
  }

  tags = {
    Name = "${local.name_prefix}-stream-backup"
  }
}
