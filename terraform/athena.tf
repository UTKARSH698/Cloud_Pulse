# ============================================================
# terraform/athena.tf
#
# Athena Workgroup with:
#   - enforced per-query data-scanned limit (free-tier guard)
#   - result files written to the dedicated Athena output bucket
#   - CloudWatch metrics enabled for query monitoring
#
# Why a dedicated workgroup?
# --------------------------
# The default Athena workgroup has no scan limit and writes results
# to wherever the caller specifies. By creating our own workgroup:
#   1. Scan limit is ENFORCED — queries that would scan more than
#      100 MB are cancelled before they cost money.
#   2. Output location is ENFORCED — results always go to our
#      controlled bucket, not an arbitrary location.
#   3. CloudWatch metrics per-workgroup let us build a cost
#      dashboard (bytes scanned / day) in cloudwatch.tf.
#
# Free-tier note
# --------------
# Athena charges $5 per TB scanned. With the 100 MB scan limit
# (variable: athena_bytes_scanned_cutoff) a single runaway query
# costs at most $0.0005. The limit applies PER QUERY — the daily
# total depends on how many queries are run.
# ============================================================

resource "aws_athena_workgroup" "cloudpulse" {
  name        = var.athena_workgroup   # "cloudpulse"
  description = "CloudPulse analytics queries — enforced scan limit and output location"

  configuration {
    # Publish per-query metrics (bytes scanned, execution time) to CloudWatch
    publish_cloudwatch_metrics_enabled = true

    # Hard limit: cancel any query that would scan more than N bytes.
    # Variable default is 100 MB — safe for a demo data lake.
    bytes_scanned_cutoff_per_query = var.athena_bytes_scanned_cutoff

    # Enforce both settings above — clients cannot override them
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_output.bucket}/query-results/"

      # Encrypt query results at rest (SSE-S3, no extra cost)
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  # Allow workgroup to be destroyed by terraform destroy (dev/staging)
  force_destroy = var.environment != "prod"
}

# ------------------------------------------------------------
# Named queries — reusable SQL saved to the Athena console
# ------------------------------------------------------------
#
# These appear in the Athena console under "Saved queries" and are
# useful for demo screenshots and for showing interviewers what
# kinds of questions the platform can answer.

resource "aws_athena_named_query" "daily_event_count" {
  name        = "cloudpulse-daily-event-count"
  description = "Total events per type for a given day"
  workgroup   = aws_athena_workgroup.cloudpulse.name
  database    = aws_glue_catalog_database.cloudpulse.name

  query = <<-SQL
    SELECT
        event_type,
        COUNT(*) AS event_count
    FROM "${aws_glue_catalog_database.cloudpulse.name}"."events"
    WHERE year  = 2026
      AND month = 3
      AND day   = 9
    GROUP BY event_type
    ORDER BY event_count DESC;
  SQL
}

resource "aws_athena_named_query" "hourly_timeseries" {
  name        = "cloudpulse-hourly-timeseries"
  description = "Event counts bucketed by hour for trend analysis"
  workgroup   = aws_athena_workgroup.cloudpulse.name
  database    = aws_glue_catalog_database.cloudpulse.name

  query = <<-SQL
    SELECT
        date_trunc('hour', from_iso8601_timestamp(timestamp)) AS hour,
        event_type,
        COUNT(*) AS event_count
    FROM "${aws_glue_catalog_database.cloudpulse.name}"."events"
    WHERE year  = 2026
      AND month = 3
      AND day   = 9
    GROUP BY 1, 2
    ORDER BY 1, 2;
  SQL
}

resource "aws_athena_named_query" "top_sessions" {
  name        = "cloudpulse-top-sessions"
  description = "Most active sessions by event count"
  workgroup   = aws_athena_workgroup.cloudpulse.name
  database    = aws_glue_catalog_database.cloudpulse.name

  query = <<-SQL
    SELECT
        session_id,
        COUNT(*)           AS event_count,
        MIN(timestamp)     AS session_start,
        MAX(timestamp)     AS session_end,
        COUNT(DISTINCT
            event_type)    AS unique_event_types
    FROM "${aws_glue_catalog_database.cloudpulse.name}"."events"
    WHERE year  = 2026
      AND month = 3
      AND day   = 9
    GROUP BY session_id
    ORDER BY event_count DESC
    LIMIT 20;
  SQL
}

resource "aws_athena_named_query" "error_events" {
  name        = "cloudpulse-error-events"
  description = "Recent error events with properties detail"
  workgroup   = aws_athena_workgroup.cloudpulse.name
  database    = aws_glue_catalog_database.cloudpulse.name

  query = <<-SQL
    SELECT
        event_id,
        timestamp,
        session_id,
        user_id,
        source,
        json_extract_scalar(properties, '$.message') AS error_message,
        json_extract_scalar(properties, '$.code')    AS error_code,
        country
    FROM "${aws_glue_catalog_database.cloudpulse.name}"."events"
    WHERE year       = 2026
      AND month      = 3
      AND event_type = 'error'
    ORDER BY timestamp DESC
    LIMIT 50;
  SQL
}

resource "aws_athena_named_query" "geographic_breakdown" {
  name        = "cloudpulse-geographic-breakdown"
  description = "Event volume by country — useful for heatmap visualisation"
  workgroup   = aws_athena_workgroup.cloudpulse.name
  database    = aws_glue_catalog_database.cloudpulse.name

  query = <<-SQL
    SELECT
        COALESCE(country, 'unknown') AS country,
        COUNT(*)                     AS event_count,
        COUNT(DISTINCT session_id)   AS unique_sessions
    FROM "${aws_glue_catalog_database.cloudpulse.name}"."events"
    WHERE year  = 2026
      AND month = 3
    GROUP BY country
    ORDER BY event_count DESC;
  SQL
}
