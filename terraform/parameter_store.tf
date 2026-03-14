# ============================================================
# terraform/parameter_store.tf
#
# AWS Systems Manager Parameter Store — runtime configuration
# for both Lambda functions.
#
# Why Parameter Store instead of Lambda env vars?
# ------------------------------------------------
# Lambda environment variables are visible in the AWS console to
# anyone with iam:GetFunctionConfiguration. Parameter Store values
# (especially SecureString) are encrypted at rest and access is
# controlled separately via IAM — a tighter security boundary.
#
# It also means config can change WITHOUT redeploying the Lambda:
#   aws ssm put-parameter --name /cloudpulse/dev/s3_prefix \
#       --value "events_v2" --overwrite
# The Lambda reads the new value on its next cold start (the
# in-process cache lasts only for the container's lifetime).
#
# Parameter types used
# --------------------
# String       — non-sensitive config (bucket names, table names)
# SecureString — sensitive values (future: API keys, secrets)
#              Encrypted with the account's default KMS key (free).
#
# Naming convention: /cloudpulse/{environment}/{key}
# This lets IAM policies use a prefix wildcard:
#   arn:aws:ssm:*:*:parameter/cloudpulse/dev/*
# ============================================================

# ------------------------------------------------------------
# Ingest Lambda parameters
# ------------------------------------------------------------

resource "aws_ssm_parameter" "s3_bucket" {
  name        = "/cloudpulse/${var.environment}/s3_bucket"
  description = "S3 data lake bucket name — read by the ingest Lambda"
  type        = "String"
  value       = aws_s3_bucket.data_lake.bucket

  # Tags inherited from provider default_tags (see main.tf)
}

resource "aws_ssm_parameter" "s3_prefix" {
  name        = "/cloudpulse/${var.environment}/s3_prefix"
  description = "Top-level S3 key prefix for raw events (e.g. 'events')"
  type        = "String"
  value       = var.s3_event_prefix
}

resource "aws_ssm_parameter" "kinesis_stream" {
  name        = "/cloudpulse/${var.environment}/kinesis_stream"
  description = "Kinesis Data Stream name — speed path for real-time analytics"
  type        = "String"
  value       = aws_kinesis_stream.events.name
}

# ------------------------------------------------------------
# Stream Processor + Realtime Lambda parameters
# ------------------------------------------------------------

resource "aws_ssm_parameter" "dynamodb_table" {
  name        = "/cloudpulse/${var.environment}/dynamodb_table"
  description = "DynamoDB table — real-time per-minute metrics with 24h TTL"
  type        = "String"
  value       = aws_dynamodb_table.realtime.name
}

# ------------------------------------------------------------
# Query Lambda parameters
# ------------------------------------------------------------

resource "aws_ssm_parameter" "athena_output_bucket" {
  name        = "/cloudpulse/${var.environment}/athena_output_bucket"
  description = "S3 bucket where Athena writes query result CSVs"
  type        = "String"
  value       = aws_s3_bucket.athena_output.bucket
}

resource "aws_ssm_parameter" "glue_database" {
  name        = "/cloudpulse/${var.environment}/glue_database"
  description = "Glue Data Catalog database name — used in Athena SQL FROM clause"
  type        = "String"
  value       = aws_glue_catalog_database.cloudpulse.name
}

resource "aws_ssm_parameter" "glue_table" {
  name        = "/cloudpulse/${var.environment}/glue_table"
  description = "Glue Data Catalog table name for the events dataset"
  type        = "String"
  value       = aws_glue_catalog_table.events.name
}

# ------------------------------------------------------------
# Shared parameters
# ------------------------------------------------------------

resource "aws_ssm_parameter" "api_endpoint" {
  name        = "/cloudpulse/${var.environment}/api_endpoint"
  description = "API Gateway invoke URL — useful for client SDKs and CI smoke tests"
  type        = "String"
  # Populated after API GW stage is created
  value       = "https://${aws_api_gateway_rest_api.cloudpulse.id}.execute-api.${local.region}.amazonaws.com/${var.api_stage}"
}

resource "aws_ssm_parameter" "cognito_user_pool_id" {
  name        = "/cloudpulse/${var.environment}/cognito_user_pool_id"
  description = "Cognito User Pool ID — needed by client apps to configure the SDK"
  type        = "String"
  value       = aws_cognito_user_pool.cloudpulse.id
}

resource "aws_ssm_parameter" "cognito_client_id" {
  name        = "/cloudpulse/${var.environment}/cognito_client_id"
  description = "Cognito App Client ID — public, safe to store as String"
  type        = "String"
  value       = aws_cognito_user_pool_client.cloudpulse.id
}

resource "aws_ssm_parameter" "cognito_domain" {
  name        = "/cloudpulse/${var.environment}/cognito_domain"
  description = "Cognito hosted UI domain for token endpoint"
  type        = "String"
  value       = "https://${aws_cognito_user_pool_domain.cloudpulse.domain}.auth.${local.region}.amazoncognito.com"
}
