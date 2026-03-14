# ============================================================
# terraform/outputs.tf
#
# Values printed after `terraform apply` and readable via
# `terraform output -json` in CI/CD for smoke tests.
# ============================================================

# ------------------------------------------------------------
# API Gateway
# ------------------------------------------------------------

output "api_endpoint" {
  description = "Base URL for all CloudPulse API calls"
  value       = "https://${aws_api_gateway_rest_api.cloudpulse.id}.execute-api.${local.region}.amazonaws.com/${var.api_stage}"
}

output "api_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.cloudpulse.id
}

# ------------------------------------------------------------
# Cognito
# ------------------------------------------------------------

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID — needed to configure client SDKs"
  value       = aws_cognito_user_pool.cloudpulse.id
}

output "cognito_client_id" {
  description = "Cognito App Client ID — public, safe to embed in frontend config"
  value       = aws_cognito_user_pool_client.cloudpulse.id
}

output "cognito_hosted_ui_url" {
  description = "Hosted sign-in page URL (open in browser to test auth)"
  value = join("", [
    "https://${aws_cognito_user_pool_domain.cloudpulse.domain}",
    ".auth.${local.region}.amazoncognito.com/login",
    "?client_id=${aws_cognito_user_pool_client.cloudpulse.id}",
    "&response_type=code",
    "&scope=openid+email+profile",
    "&redirect_uri=http://localhost:3000/callback",
  ])
}

output "cognito_token_endpoint" {
  description = "Token endpoint for Postman / curl auth requests"
  value       = "https://${aws_cognito_user_pool_domain.cloudpulse.domain}.auth.${local.region}.amazoncognito.com/oauth2/token"
}

# ------------------------------------------------------------
# S3
# ------------------------------------------------------------

output "data_lake_bucket" {
  description = "S3 data lake bucket name — where raw events are stored"
  value       = aws_s3_bucket.data_lake.bucket
}

output "athena_output_bucket" {
  description = "S3 bucket for Athena query result CSVs"
  value       = aws_s3_bucket.athena_output.bucket
}

# ------------------------------------------------------------
# Lambda
# ------------------------------------------------------------

output "ingest_function_name" {
  description = "Ingest Lambda function name"
  value       = aws_lambda_function.ingest.function_name
}

output "query_function_name" {
  description = "Query Lambda function name"
  value       = aws_lambda_function.query.function_name
}

output "stream_processor_function_name" {
  description = "Stream Processor Lambda function name"
  value       = aws_lambda_function.stream_processor.function_name
}

output "realtime_function_name" {
  description = "Realtime Lambda function name"
  value       = aws_lambda_function.realtime.function_name
}

# ------------------------------------------------------------
# Kinesis + DynamoDB (real-time layer)
# ------------------------------------------------------------

output "kinesis_stream_name" {
  description = "Kinesis Data Stream name — speed path for real-time analytics"
  value       = aws_kinesis_stream.events.name
}

output "dynamodb_table_name" {
  description = "DynamoDB table name — real-time metrics store"
  value       = aws_dynamodb_table.realtime.name
}

# ------------------------------------------------------------
# Glue + Athena
# ------------------------------------------------------------

output "glue_database" {
  description = "Glue Data Catalog database name"
  value       = aws_glue_catalog_database.cloudpulse.name
}

output "glue_crawler_name" {
  description = "Glue Crawler name — run manually after first ingest: aws glue start-crawler --name <value>"
  value       = aws_glue_crawler.events.name
}

output "athena_workgroup" {
  description = "Athena workgroup name"
  value       = aws_athena_workgroup.cloudpulse.name
}

# ------------------------------------------------------------
# CloudWatch
# ------------------------------------------------------------

output "cloudwatch_dashboard_url" {
  description = "Direct link to the CloudWatch dashboard"
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${local.name_prefix}"
}

# ------------------------------------------------------------
# Quick-start summary (printed last)
# ------------------------------------------------------------

output "quick_start" {
  description = "Copy-paste commands to test the deployment"
  value       = <<-EOT

  ── CloudPulse deployed ────────────────────────────────────────

  API endpoint  : https://${aws_api_gateway_rest_api.cloudpulse.id}.execute-api.${local.region}.amazonaws.com/${var.api_stage}
  Cognito pool  : ${aws_cognito_user_pool.cloudpulse.id}
  Cognito client: ${aws_cognito_user_pool_client.cloudpulse.id}
  Data lake     : s3://${aws_s3_bucket.data_lake.bucket}
  Dashboard     : https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${local.name_prefix}

  1. Get a token:
     aws cognito-idp initiate-auth \
       --auth-flow USER_PASSWORD_AUTH \
       --client-id ${aws_cognito_user_pool_client.cloudpulse.id} \
       --auth-parameters USERNAME=<email>,PASSWORD=<password> \
       --query 'AuthenticationResult.AccessToken' --output text

  2. Ingest an event:
     curl -X POST <api_endpoint>/events \
       -H "Authorization: Bearer <token>" \
       -H "Content-Type: application/json" \
       -d '{"event_type":"page_view","session_id":"sess_001","source":"web","properties":{"page":"/home"}}'

  3. Run the Glue Crawler:
     aws glue start-crawler --name ${aws_glue_crawler.events.name}

  4. Query analytics:
     curl "<api_endpoint>/query?query_type=event_count&date_from=$(date +%Y-%m-%d)&date_to=$(date +%Y-%m-%d)" \
       -H "Authorization: Bearer <token>"

  ───────────────────────────────────────────────────────────────
  EOT
}
