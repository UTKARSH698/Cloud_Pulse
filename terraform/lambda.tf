# ============================================================
# terraform/lambda.tf
#
# Packages and deploys both Lambda functions.
#
# Packaging strategy
# ------------------
# Terraform's `archive_file` data source zips the Lambda source
# directory at plan time.  Dependencies (pydantic) must be installed
# into the source directory first — the CI/CD workflow does:
#
#   pip install -r lambdas/ingest/requirements.txt \
#       -t lambdas/ingest/ --upgrade
#
# The resulting ZIP is what Terraform uploads to Lambda.
# Source-code hash is tracked so Lambda only re-deploys when
# the ZIP content actually changes (avoids unnecessary cold starts).
# ============================================================

# ------------------------------------------------------------
# ZIP archives — built from the local lambda source directories
# ------------------------------------------------------------

data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/ingest"
  output_path = "${path.root}/../.build/ingest.zip"
  excludes    = [
    "__pycache__",
    "*.pyc",
    "*.pyo",
    "tests",
    "requirements.txt",   # already installed into source_dir by CI
  ]
}

data "archive_file" "query" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/query"
  output_path = "${path.root}/../.build/query.zip"
  excludes    = [
    "__pycache__",
    "*.pyc",
    "*.pyo",
    "tests",
    "requirements.txt",
  ]
}

data "archive_file" "stream_processor" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/stream_processor"
  output_path = "${path.root}/../.build/stream_processor.zip"
  excludes    = ["__pycache__", "*.pyc", "*.pyo", "requirements.txt"]
}

data "archive_file" "realtime" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/realtime"
  output_path = "${path.root}/../.build/realtime.zip"
  excludes    = ["__pycache__", "*.pyc", "*.pyo", "requirements.txt"]
}

data "archive_file" "worker" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/worker"
  output_path = "${path.root}/../.build/worker.zip"
  excludes    = ["__pycache__", "*.pyc", "*.pyo", "requirements.txt"]
}

# ------------------------------------------------------------
# CloudWatch Log Groups — created before the Lambdas so
# Terraform controls retention (otherwise Lambda auto-creates
# them with no retention, which leaks logs forever on free tier)
# ------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.name_prefix}-ingest"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${local.name_prefix}-query"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "stream_processor" {
  name              = "/aws/lambda/${local.name_prefix}-stream-processor"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "realtime" {
  name              = "/aws/lambda/${local.name_prefix}-realtime"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.name_prefix}-worker"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------------------
# Ingest Lambda
# ------------------------------------------------------------

resource "aws_lambda_function" "ingest" {
  function_name = "${local.name_prefix}-ingest"
  description   = "CloudPulse — receives analytics events from API Gateway and enqueues them to SQS"

  # Deployment package
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  # Runtime
  runtime = var.lambda_runtime
  handler = "handler.handler"   # file: handler.py  function: handler()

  # Resources
  role        = aws_iam_role.ingest.arn
  timeout     = var.lambda_timeout_ingest
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      ENVIRONMENT  = var.environment
      LOG_LEVEL    = var.environment == "prod" ? "WARNING" : "INFO"
      POWERTOOLS_SERVICE_NAME = "${local.name_prefix}-ingest"
    }
  }

  # Ensure the log group exists before Lambda tries to write to it
  depends_on = [
    aws_cloudwatch_log_group.ingest,
    aws_iam_role_policy_attachment.ingest_logs,
    aws_iam_role_policy_attachment.ingest_sqs,
    aws_iam_role_policy_attachment.ingest_ssm,
    aws_iam_role_policy_attachment.ingest_kinesis,
  ]
}

# ------------------------------------------------------------
# Query Lambda
# ------------------------------------------------------------

resource "aws_lambda_function" "query" {
  function_name = "${local.name_prefix}-query"
  description   = "CloudPulse — executes pre-built Athena queries and returns JSON results"

  filename         = data.archive_file.query.output_path
  source_code_hash = data.archive_file.query.output_base64sha256

  runtime = var.lambda_runtime
  handler = "handler.handler"

  role        = aws_iam_role.query.arn
  timeout     = var.lambda_timeout_query   # 29 s — Athena polling needs headroom
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      ENVIRONMENT      = var.environment
      LOG_LEVEL        = var.environment == "prod" ? "WARNING" : "INFO"
      POWERTOOLS_SERVICE_NAME = "${local.name_prefix}-query"
      ATHENA_WORKGROUP = var.athena_workgroup
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.query,
    aws_iam_role_policy_attachment.query_logs,
    aws_iam_role_policy_attachment.query_s3,
    aws_iam_role_policy_attachment.query_athena,
    aws_iam_role_policy_attachment.query_glue,
    aws_iam_role_policy_attachment.query_ssm,
  ]
}

# ------------------------------------------------------------
# Lambda aliases — "live" alias always points to $LATEST
# API Gateway targets the alias so future version pinning is easy
# ------------------------------------------------------------

# ------------------------------------------------------------
# Stream Processor Lambda — Kinesis consumer
# ------------------------------------------------------------

resource "aws_lambda_function" "stream_processor" {
  function_name = "${local.name_prefix}-stream-processor"
  description   = "CloudPulse — aggregates Kinesis stream records into DynamoDB real-time metrics"

  filename         = data.archive_file.stream_processor.output_path
  source_code_hash = data.archive_file.stream_processor.output_base64sha256

  runtime = var.lambda_runtime
  handler = "handler.handler"

  role        = aws_iam_role.stream_processor.arn
  timeout     = 60
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      ENVIRONMENT = var.environment
      LOG_LEVEL   = var.environment == "prod" ? "WARNING" : "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.stream_processor,
    aws_iam_role_policy_attachment.stream_processor_kinesis,
    aws_iam_role_policy_attachment.stream_processor_dynamodb,
    aws_iam_role_policy_attachment.stream_processor_ssm,
    aws_iam_role_policy_attachment.stream_processor_logs,
  ]
}

# Kinesis → Lambda event source mapping
# - ReportBatchItemFailures: only retry the specific records that failed, not the whole batch
# - bisect_on_function_error: if the Lambda itself crashes, split the batch to isolate poison records
# - maximum_retry_attempts: cap retries to avoid infinite loops on persistent failures
# - maximum_record_age: skip records older than 1 hour (stale real-time data has no value)
resource "aws_lambda_event_source_mapping" "kinesis_stream_processor" {
  event_source_arn                   = aws_kinesis_stream.events.arn
  function_name                      = aws_lambda_function.stream_processor.function_name
  starting_position                  = "LATEST"
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  bisect_batch_on_function_error     = true
  maximum_retry_attempts             = 3
  maximum_record_age_in_seconds      = 3600  # 1 hour — stale records skip to DLQ

  # Enable partial batch success reporting — only failed records are retried
  function_response_types = ["ReportBatchItemFailures"]

  # Send records that exhaust retries to a DLQ for inspection
  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.kinesis_dlq.arn
    }
  }
}

# ------------------------------------------------------------
# Realtime Lambda — serves GET /realtime from API Gateway
# ------------------------------------------------------------

resource "aws_lambda_function" "realtime" {
  function_name = "${local.name_prefix}-realtime"
  description   = "CloudPulse — reads real-time metrics from DynamoDB for the dashboard"

  filename         = data.archive_file.realtime.output_path
  source_code_hash = data.archive_file.realtime.output_base64sha256

  runtime = var.lambda_runtime
  handler = "handler.handler"

  role        = aws_iam_role.realtime.arn
  timeout     = 10
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      ENVIRONMENT = var.environment
      LOG_LEVEL   = var.environment == "prod" ? "WARNING" : "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.realtime,
    aws_iam_role_policy_attachment.realtime_dynamodb,
    aws_iam_role_policy_attachment.realtime_ssm,
    aws_iam_role_policy_attachment.realtime_logs,
  ]
}

resource "aws_lambda_alias" "realtime_live" {
  name             = "live"
  function_name    = aws_lambda_function.realtime.function_name
  function_version = "$LATEST"
}

resource "aws_lambda_permission" "realtime_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.realtime.function_name
  qualifier     = aws_lambda_alias.realtime_live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cloudpulse.execution_arn}/*/*"
}

# ------------------------------------------------------------
# Lambda aliases — "live" alias always points to $LATEST
# ------------------------------------------------------------

resource "aws_lambda_alias" "ingest_live" {
  name             = "live"
  function_name    = aws_lambda_function.ingest.function_name
  function_version = "$LATEST"
}

resource "aws_lambda_alias" "query_live" {
  name             = "live"
  function_name    = aws_lambda_function.query.function_name
  function_version = "$LATEST"
}

# ------------------------------------------------------------
# Permissions — allow API Gateway to invoke each Lambda alias
# ------------------------------------------------------------

resource "aws_lambda_permission" "ingest_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  qualifier     = aws_lambda_alias.ingest_live.name
  principal     = "apigateway.amazonaws.com"
  # Restrict to this specific API + stage — no other API can invoke it
  source_arn    = "${aws_api_gateway_rest_api.cloudpulse.execution_arn}/*/*"
}

resource "aws_lambda_permission" "query_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query.function_name
  qualifier     = aws_lambda_alias.query_live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cloudpulse.execution_arn}/*/*"
}

# ------------------------------------------------------------
# Worker Lambda — SQS consumer → S3 writer
# ------------------------------------------------------------

resource "aws_lambda_function" "worker" {
  function_name = "${local.name_prefix}-worker"
  description   = "CloudPulse — consumes SQS events queue and persists records to S3 data lake"

  filename         = data.archive_file.worker.output_path
  source_code_hash = data.archive_file.worker.output_base64sha256

  runtime = var.lambda_runtime
  handler = "handler.handler"

  role        = aws_iam_role.worker.arn
  timeout     = 30   # must be <= sqs visibility_timeout_seconds
  memory_size = var.lambda_memory_mb

  environment {
    variables = {
      ENVIRONMENT = var.environment
      LOG_LEVEL   = var.environment == "prod" ? "WARNING" : "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.worker,
    aws_iam_role_policy_attachment.worker_logs,
    aws_iam_role_policy_attachment.worker_s3,
    aws_iam_role_policy_attachment.worker_sqs,
    aws_iam_role_policy_attachment.worker_ssm,
  ]
}

# SQS → Worker Lambda event source mapping
# batch_size=10 limits blast radius if a batch fails (entire batch is retried)
resource "aws_lambda_event_source_mapping" "sqs_worker" {
  event_source_arn = aws_sqs_queue.events.arn
  function_name    = aws_lambda_function.worker.function_name
  batch_size       = 10
  enabled          = true
}
