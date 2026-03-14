# ============================================================
# terraform/iam.tf
#
# IAM roles and policies for both Lambda functions.
#
# Principle of least privilege — each Lambda gets exactly the
# permissions it needs, scoped to the specific resources it owns:
#
#   ingest Lambda
#     - s3:PutObject          → data lake bucket (events/ prefix only)
#     - ssm:GetParameter      → /cloudpulse/{env}/s3_bucket + s3_prefix
#     - logs:*                → its own log group
#
#   query Lambda
#     - s3:GetObject / List   → data lake bucket (read-only)
#     - s3:PutObject          → Athena output bucket (results only)
#     - s3:GetBucketLocation  → both buckets (required by Athena SDK)
#     - athena:*              → cloudpulse workgroup only
#     - glue:GetDatabase/Table/Partition → cloudpulse database only
#     - ssm:GetParameter      → /cloudpulse/{env}/* params
#     - logs:*                → its own log group
#
# No Lambda has s3:DeleteObject, iam:*, or wildcard resource ARNs.
# ============================================================

# ------------------------------------------------------------
# Shared: trust policy — allows Lambda service to assume roles
# ------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "LambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ============================================================
# INGEST LAMBDA ROLE
# ============================================================

resource "aws_iam_role" "ingest" {
  name               = "${local.name_prefix}-ingest-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# --- Policy: CloudWatch Logs ---

data "aws_iam_policy_document" "ingest_logs" {
  statement {
    sid    = "CreateLogGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:*",
    ]
  }

  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-ingest:*",
    ]
  }
}

resource "aws_iam_policy" "ingest_logs" {
  name   = "${local.name_prefix}-ingest-logs"
  policy = data.aws_iam_policy_document.ingest_logs.json
}

resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest.name
  policy_arn = aws_iam_policy.ingest_logs.arn
}

# --- Policy: S3 write (events prefix only) ---

data "aws_iam_policy_document" "ingest_s3" {
  statement {
    sid    = "PutEvents"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      # Scoped to the events/ prefix — ingest cannot touch any other prefix
      "${aws_s3_bucket.data_lake.arn}/${var.s3_event_prefix}/*",
    ]
  }
}

resource "aws_iam_policy" "ingest_s3" {
  name   = "${local.name_prefix}-ingest-s3"
  policy = data.aws_iam_policy_document.ingest_s3.json
}

resource "aws_iam_role_policy_attachment" "ingest_s3" {
  role       = aws_iam_role.ingest.name
  policy_arn = aws_iam_policy.ingest_s3.arn
}

# --- Policy: Kinesis PutRecord (speed path dual-write) ---

data "aws_iam_policy_document" "ingest_kinesis" {
  statement {
    sid    = "PutStreamRecords"
    effect = "Allow"
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords",
    ]
    resources = [aws_kinesis_stream.events.arn]
  }
}

resource "aws_iam_policy" "ingest_kinesis" {
  name   = "${local.name_prefix}-ingest-kinesis"
  policy = data.aws_iam_policy_document.ingest_kinesis.json
}

resource "aws_iam_role_policy_attachment" "ingest_kinesis" {
  role       = aws_iam_role.ingest.name
  policy_arn = aws_iam_policy.ingest_kinesis.arn
}

# --- Policy: SSM Parameter Store (ingest params only) ---

data "aws_iam_policy_document" "ingest_ssm" {
  statement {
    sid    = "ReadIngestParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cloudpulse/${var.environment}/s3_bucket",
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cloudpulse/${var.environment}/s3_prefix",
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cloudpulse/${var.environment}/kinesis_stream",
    ]
  }
}

resource "aws_iam_policy" "ingest_ssm" {
  name   = "${local.name_prefix}-ingest-ssm"
  policy = data.aws_iam_policy_document.ingest_ssm.json
}

resource "aws_iam_role_policy_attachment" "ingest_ssm" {
  role       = aws_iam_role.ingest.name
  policy_arn = aws_iam_policy.ingest_ssm.arn
}

# ============================================================
# STREAM PROCESSOR LAMBDA ROLE
# ============================================================

resource "aws_iam_role" "stream_processor" {
  name               = "${local.name_prefix}-stream-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "stream_processor_kinesis" {
  statement {
    sid    = "ReadStream"
    effect = "Allow"
    actions = [
      "kinesis:GetRecords",
      "kinesis:GetShardIterator",
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:ListShards",
      "kinesis:ListStreams",
    ]
    resources = [aws_kinesis_stream.events.arn]
  }
}

resource "aws_iam_policy" "stream_processor_kinesis" {
  name   = "${local.name_prefix}-stream-processor-kinesis"
  policy = data.aws_iam_policy_document.stream_processor_kinesis.json
}

resource "aws_iam_role_policy_attachment" "stream_processor_kinesis" {
  role       = aws_iam_role.stream_processor.name
  policy_arn = aws_iam_policy.stream_processor_kinesis.arn
}

data "aws_iam_policy_document" "stream_processor_dynamodb" {
  statement {
    sid    = "WritMetrics"
    effect = "Allow"
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:PutItem",
    ]
    resources = [aws_dynamodb_table.realtime.arn]
  }
}

resource "aws_iam_policy" "stream_processor_dynamodb" {
  name   = "${local.name_prefix}-stream-processor-dynamodb"
  policy = data.aws_iam_policy_document.stream_processor_dynamodb.json
}

resource "aws_iam_role_policy_attachment" "stream_processor_dynamodb" {
  role       = aws_iam_role.stream_processor.name
  policy_arn = aws_iam_policy.stream_processor_dynamodb.arn
}

data "aws_iam_policy_document" "stream_processor_ssm" {
  statement {
    sid    = "ReadStreamProcessorParams"
    effect = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cloudpulse/${var.environment}/dynamodb_table",
    ]
  }
}

resource "aws_iam_policy" "stream_processor_ssm" {
  name   = "${local.name_prefix}-stream-processor-ssm"
  policy = data.aws_iam_policy_document.stream_processor_ssm.json
}

resource "aws_iam_role_policy_attachment" "stream_processor_ssm" {
  role       = aws_iam_role.stream_processor.name
  policy_arn = aws_iam_policy.stream_processor_ssm.arn
}

data "aws_iam_policy_document" "stream_processor_logs" {
  statement {
    sid    = "CreateLogGroup"
    effect = "Allow"
    actions = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:*"]
  }
  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-stream-processor:*",
    ]
  }
}

resource "aws_iam_policy" "stream_processor_logs" {
  name   = "${local.name_prefix}-stream-processor-logs"
  policy = data.aws_iam_policy_document.stream_processor_logs.json
}

resource "aws_iam_role_policy_attachment" "stream_processor_logs" {
  role       = aws_iam_role.stream_processor.name
  policy_arn = aws_iam_policy.stream_processor_logs.arn
}

# ============================================================
# REALTIME LAMBDA ROLE
# ============================================================

resource "aws_iam_role" "realtime" {
  name               = "${local.name_prefix}-realtime-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "realtime_dynamodb" {
  statement {
    sid    = "ReadMetrics"
    effect = "Allow"
    actions = [
      "dynamodb:Query",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.realtime.arn]
  }
}

resource "aws_iam_policy" "realtime_dynamodb" {
  name   = "${local.name_prefix}-realtime-dynamodb"
  policy = data.aws_iam_policy_document.realtime_dynamodb.json
}

resource "aws_iam_role_policy_attachment" "realtime_dynamodb" {
  role       = aws_iam_role.realtime.name
  policy_arn = aws_iam_policy.realtime_dynamodb.arn
}

data "aws_iam_policy_document" "realtime_ssm" {
  statement {
    sid    = "ReadRealtimeParams"
    effect = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cloudpulse/${var.environment}/dynamodb_table",
    ]
  }
}

resource "aws_iam_policy" "realtime_ssm" {
  name   = "${local.name_prefix}-realtime-ssm"
  policy = data.aws_iam_policy_document.realtime_ssm.json
}

resource "aws_iam_role_policy_attachment" "realtime_ssm" {
  role       = aws_iam_role.realtime.name
  policy_arn = aws_iam_policy.realtime_ssm.arn
}

data "aws_iam_policy_document" "realtime_logs" {
  statement {
    sid    = "CreateLogGroup"
    effect = "Allow"
    actions = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:*"]
  }
  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-realtime:*",
    ]
  }
}

resource "aws_iam_policy" "realtime_logs" {
  name   = "${local.name_prefix}-realtime-logs"
  policy = data.aws_iam_policy_document.realtime_logs.json
}

resource "aws_iam_role_policy_attachment" "realtime_logs" {
  role       = aws_iam_role.realtime.name
  policy_arn = aws_iam_policy.realtime_logs.arn
}

# ============================================================
# QUERY LAMBDA ROLE
# ============================================================

resource "aws_iam_role" "query" {
  name               = "${local.name_prefix}-query-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# --- Policy: CloudWatch Logs ---

data "aws_iam_policy_document" "query_logs" {
  statement {
    sid     = "CreateLogGroup"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup"]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:*",
    ]
  }

  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-query:*",
    ]
  }
}

resource "aws_iam_policy" "query_logs" {
  name   = "${local.name_prefix}-query-logs"
  policy = data.aws_iam_policy_document.query_logs.json
}

resource "aws_iam_role_policy_attachment" "query_logs" {
  role       = aws_iam_role.query.name
  policy_arn = aws_iam_policy.query_logs.arn
}

# --- Policy: S3 read (data lake) + write (Athena output only) ---

data "aws_iam_policy_document" "query_s3" {
  # Read events from the data lake
  statement {
    sid    = "ReadDataLake"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",   # required by Athena SDK before submitting a query
    ]
    resources = [
      aws_s3_bucket.data_lake.arn,
      "${aws_s3_bucket.data_lake.arn}/*",
    ]
  }

  # Write Athena result CSVs to the output bucket
  statement {
    sid    = "WriteAthenaResults"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",           # Athena reads back its own results to return them
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.athena_output.arn,
      "${aws_s3_bucket.athena_output.arn}/query-results/*",
    ]
  }
}

resource "aws_iam_policy" "query_s3" {
  name   = "${local.name_prefix}-query-s3"
  policy = data.aws_iam_policy_document.query_s3.json
}

resource "aws_iam_role_policy_attachment" "query_s3" {
  role       = aws_iam_role.query.name
  policy_arn = aws_iam_policy.query_s3.arn
}

# --- Policy: Athena (cloudpulse workgroup only) ---

data "aws_iam_policy_document" "query_athena" {
  statement {
    sid    = "RunAthenaQueries"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
    ]
    resources = [
      "arn:aws:athena:${local.region}:${local.account_id}:workgroup/${var.athena_workgroup}",
    ]
  }
}

resource "aws_iam_policy" "query_athena" {
  name   = "${local.name_prefix}-query-athena"
  policy = data.aws_iam_policy_document.query_athena.json
}

resource "aws_iam_role_policy_attachment" "query_athena" {
  role       = aws_iam_role.query.name
  policy_arn = aws_iam_policy.query_athena.arn
}

# --- Policy: Glue Data Catalog (read-only, cloudpulse database only) ---

data "aws_iam_policy_document" "query_glue" {
  statement {
    sid    = "ReadGlueCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
    ]
    resources = [
      # Catalog resource is account-level
      "arn:aws:glue:${local.region}:${local.account_id}:catalog",
      # Scoped to the cloudpulse database and its tables only
      "arn:aws:glue:${local.region}:${local.account_id}:database/${local.name_prefix}",
      "arn:aws:glue:${local.region}:${local.account_id}:table/${local.name_prefix}/*",
    ]
  }
}

resource "aws_iam_policy" "query_glue" {
  name   = "${local.name_prefix}-query-glue"
  policy = data.aws_iam_policy_document.query_glue.json
}

resource "aws_iam_role_policy_attachment" "query_glue" {
  role       = aws_iam_role.query.name
  policy_arn = aws_iam_policy.query_glue.arn
}

# --- Policy: SSM Parameter Store (all cloudpulse params for this env) ---

data "aws_iam_policy_document" "query_ssm" {
  statement {
    sid    = "ReadQueryParams"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      # Wildcard only within /cloudpulse/{env}/ — not account-wide
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/cloudpulse/${var.environment}/*",
    ]
  }
}

resource "aws_iam_policy" "query_ssm" {
  name   = "${local.name_prefix}-query-ssm"
  policy = data.aws_iam_policy_document.query_ssm.json
}

resource "aws_iam_role_policy_attachment" "query_ssm" {
  role       = aws_iam_role.query.name
  policy_arn = aws_iam_policy.query_ssm.arn
}

# ============================================================
# API GATEWAY CLOUDWATCH LOGS ROLE
# ============================================================
#
# API Gateway needs an account-level IAM role to write access
# logs to CloudWatch. This is a one-time account setting that
# must be set before access_log_settings on a stage will work.

resource "aws_iam_role" "api_gateway_cloudwatch" {
  name               = "${local.name_prefix}-apigw-cw-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json
}

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    sid     = "ApiGatewayAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  role       = aws_iam_role.api_gateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# ============================================================
# GLUE CRAWLER ROLE
# ============================================================
#
# Glue Crawler needs to read from S3 and write schema to the
# Data Catalog. This is a separate role from the Lambda roles.

resource "aws_iam_role" "glue_crawler" {
  name               = "${local.name_prefix}-glue-crawler-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    sid     = "GlueAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# AWS-managed policy — grants Glue the minimum it needs for crawling
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Glue also needs to read from our specific S3 bucket
data "aws_iam_policy_document" "glue_s3" {
  statement {
    sid    = "CrawlDataLake"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.data_lake.arn,
      "${aws_s3_bucket.data_lake.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "glue_s3" {
  name   = "${local.name_prefix}-glue-s3"
  policy = data.aws_iam_policy_document.glue_s3.json
}

resource "aws_iam_role_policy_attachment" "glue_s3" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = aws_iam_policy.glue_s3.arn
}
