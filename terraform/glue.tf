# ============================================================
# terraform/glue.tf
#
# Glue Data Catalog database + Crawler.
#
# How Glue fits in the pipeline
# ------------------------------
#
#   S3 (raw JSON events, Hive-partitioned)
#     ↓  Glue Crawler runs on schedule
#   Glue Data Catalog
#     • Database: cloudpulse-dev
#     • Table:    events  (schema auto-inferred from JSON samples)
#     • Partitions: year, month, day, event_type
#     ↓  Athena reads catalog metadata
#   Athena SQL query
#
# Without the Crawler, Athena has no schema and cannot query the data.
# The Crawler inspects a sample of JSON files, infers column types,
# and writes the schema to the Data Catalog automatically.
#
# Free-tier note
# --------------
# Glue Crawler runs are charged at $0.44/DPU-hour with a 10-minute
# minimum per run. One DPU-hour = ~$0.07 per run at minimum.
# The default schedule (every 6 h) = max ~4 runs/day = ~$0.30/day.
# For a demo / portfolio project, run the crawler MANUALLY after
# ingesting events and disable the schedule to stay at zero cost:
#   aws glue start-crawler --name cloudpulse-dev-crawler
# The schedule variable in variables.tf lets you set it from CI/CD.
# ============================================================

# ------------------------------------------------------------
# Glue Data Catalog Database
# ------------------------------------------------------------

resource "aws_glue_catalog_database" "cloudpulse" {
  name        = local.name_prefix   # "cloudpulse-dev"
  description = "CloudPulse analytics events — schema managed by Glue Crawler"

  # Location URI helps tools that inspect the catalog understand the data origin
  location_uri = "s3://${aws_s3_bucket.data_lake.bucket}/${var.s3_event_prefix}/"
}

# ------------------------------------------------------------
# Glue Crawler
# ------------------------------------------------------------
#
# The Crawler scans the S3 events prefix, detects new partitions
# (e.g. a new day's data), and updates the Data Catalog table.
#
# Key settings explained
# ----------------------
# recrawl_policy CRAWL_NEW_FOLDERS_ONLY — on subsequent runs, only
#   scan S3 folders added since the last crawl. Much faster and
#   cheaper than re-scanning the whole bucket every time.
#
# configuration (JSON) — tells the Crawler to CREATE a single
#   table named "events" rather than one table per top-level prefix.
#   Also sets version = 1.0 to use the latest Hive-compatible format.
#
# schema_change_policy — UPDATE_IN_DATABASE on schema change (e.g. a
#   new "properties" sub-key appears); LOG on deleted partitions so
#   we don't lose catalog entries if a partition is accidentally removed.

resource "aws_glue_crawler" "events" {
  name          = "${local.name_prefix}-crawler"
  role          = aws_iam_role.glue_crawler.arn
  database_name = aws_glue_catalog_database.cloudpulse.name
  description   = "Crawls S3 events prefix and keeps the Glue Data Catalog table up to date"

  # What to crawl
  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/${var.s3_event_prefix}/"
  }

  # Run every 6 hours by default (override in variables.tf or set to null for manual only)
  schedule = var.glue_crawler_schedule

  # Only scan folders added since the last crawl — cost and speed optimisation
  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  # How to handle schema drift
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"   # add new columns automatically
    delete_behavior = "LOG"                  # log deleted partitions, don't remove
  }

  # Crawler configuration — produces one table named "events"
  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
    Grouping = {
      # Group all files under events/ into a single table
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })
}

# ------------------------------------------------------------
# Glue Catalog Table — pre-defined schema
# ------------------------------------------------------------
#
# We seed the Data Catalog with a known schema BEFORE the Crawler
# runs for the first time. This means Athena can query the table
# immediately after the first event is ingested, without waiting
# for the Crawler schedule.
#
# Partition keys match the Hive-style S3 key from models.py:
#   events/year=2026/month=03/day=09/event_type=page_view/
#
# The Crawler will ADD any new columns it discovers but will
# never remove columns we define here (schema_change_policy LOG).

resource "aws_glue_catalog_table" "events" {
  database_name = aws_glue_catalog_database.cloudpulse.name
  name          = "events"
  description   = "Raw analytics events written by the ingest Lambda"

  table_type = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    "classification"      = "json"
    "compressionType"     = "none"
    "typeOfData"          = "file"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake.bucket}/${var.s3_event_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        "serialization.format" = "1"
        "ignore.malformed.json" = "true"
      }
    }

    # Columns — match the fields in AnalyticsEvent.to_s3_record()
    columns {
      name = "event_id"
      type = "string"
    }
    columns {
      name = "event_type"
      type = "string"
    }
    columns {
      name = "timestamp"
      type = "string"   # stored as ISO-8601 string; cast in SQL when needed
    }
    columns {
      name = "session_id"
      type = "string"
    }
    columns {
      name = "user_id"
      type = "string"
    }
    columns {
      name = "source"
      type = "string"
    }
    columns {
      name = "properties"
      type = "string"   # JSON blob; use json_extract() in Athena
    }
    columns {
      name = "ip_address"
      type = "string"
    }
    columns {
      name = "user_agent"
      type = "string"
    }
    columns {
      name = "country"
      type = "string"
    }
    columns {
      name = "region"
      type = "string"
    }
    columns {
      name = "referrer"
      type = "string"
    }
  }

  # Partition keys — must match the Hive folder names exactly
  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }
  partition_keys {
    name = "day"
    type = "int"
  }
  partition_keys {
    name = "event_type"
    type = "string"
  }
}
