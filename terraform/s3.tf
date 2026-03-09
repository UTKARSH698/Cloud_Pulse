# ============================================================
# terraform/s3.tf
#
# Two S3 buckets:
#   1. Data lake  — receives raw JSON events from the ingest Lambda.
#                   Glue Crawler reads from here; Athena queries it.
#   2. Athena out — Athena writes query-result CSVs here.
#                   Required by Athena; we give it a short lifecycle
#                   so stale result files don't accumulate.
#
# Both buckets are private, versioning-off (free tier), and
# encrypted with SSE-S3 (no KMS cost).
# ============================================================

# ------------------------------------------------------------
# 1. Data lake bucket
# ------------------------------------------------------------

resource "aws_s3_bucket" "data_lake" {
  # Globally unique: "cloudpulse-dev-events-123456789012"
  bucket        = "${local.name_prefix}-events-${local.account_id}"
  force_destroy = var.environment != "prod"   # safe to wipe in dev/staging
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Disabled"   # not needed for analytics events; saves storage cost
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"   # SSE-S3 — free, no KMS API call charges
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {
      prefix = "${var.s3_event_prefix}/"   # only affects event objects
    }

    # Move objects to S3 Standard-IA after N days (default 30).
    # S3-IA costs ~60 % less per GB than Standard — important once
    # events accumulate beyond the free-tier 5 GB limit.
    transition {
      days          = var.s3_lifecycle_days
      storage_class = "STANDARD_IA"
    }
  }
}

# ------------------------------------------------------------
# 2. Athena query results bucket
# ------------------------------------------------------------

resource "aws_s3_bucket" "athena_output" {
  bucket        = "${local.name_prefix}-athena-output-${local.account_id}"
  force_destroy = true   # result files are ephemeral; safe to destroy always
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_output" {
  bucket = aws_s3_bucket.athena_output.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_output" {
  bucket                  = aws_s3_bucket.athena_output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_output" {
  bucket = aws_s3_bucket.athena_output.id

  rule {
    id     = "expire-results"
    status = "Enabled"

    filter { prefix = "query-results/" }

    # Athena result CSVs are only needed until the Lambda returns them
    # to the caller. Expire after 1 day to prevent accumulation.
    expiration {
      days = 1
    }
  }
}
