# ============================================================
# terraform/api_gateway.tf
#
# REST API (API Gateway v1) with:
#   - Cognito User Pool authorizer on every route
#   - POST /events          → ingest Lambda alias
#   - POST /events/batch    → ingest Lambda alias
#   - GET  /query           → query Lambda alias
#   - OPTIONS  (each route) → CORS preflight (no auth required)
#
# Why REST API (v1) over HTTP API (v2)?
#   HTTP API is cheaper but lacks per-method throttling and
#   usage plans — both are useful to show in a portfolio.
#   REST API also has a built-in request validator we use to
#   reject missing Content-Type before the Lambda is invoked.
# ============================================================

# ------------------------------------------------------------
# REST API
# ------------------------------------------------------------

resource "aws_api_gateway_rest_api" "cloudpulse" {
  name        = "${local.name_prefix}-api"
  description = "CloudPulse Serverless Analytics Platform — ingest and query endpoints"

  endpoint_configuration {
    types = ["REGIONAL"]   # REGIONAL is free-tier eligible; EDGE needs CloudFront
  }
}

# ------------------------------------------------------------
# Cognito authorizer
# (defined here; the User Pool is created in cognito.tf)
# ------------------------------------------------------------

resource "aws_api_gateway_authorizer" "cognito" {
  name          = "${local.name_prefix}-cognito-auth"
  rest_api_id   = aws_api_gateway_rest_api.cloudpulse.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [aws_cognito_user_pool.cloudpulse.arn]

  # API GW reads the Authorization header and validates the JWT
  identity_source = "method.request.header.Authorization"
}

# ------------------------------------------------------------
# Request validator — rejects calls without a body on POST routes
# before Lambda is ever invoked (saves invocation costs)
# ------------------------------------------------------------

resource "aws_api_gateway_request_validator" "body" {
  name                        = "validate-body"
  rest_api_id                 = aws_api_gateway_rest_api.cloudpulse.id
  validate_request_body       = true
  validate_request_parameters = false
}

# ============================================================
# /events resource
# ============================================================

resource "aws_api_gateway_resource" "events" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  parent_id   = aws_api_gateway_rest_api.cloudpulse.root_resource_id
  path_part   = "events"
}

# --- POST /events ---

resource "aws_api_gateway_method" "events_post" {
  rest_api_id          = aws_api_gateway_rest_api.cloudpulse.id
  resource_id          = aws_api_gateway_resource.events.id
  http_method          = "POST"
  authorization        = "COGNITO_USER_POOLS"
  authorizer_id        = aws_api_gateway_authorizer.cognito.id
  request_validator_id = aws_api_gateway_request_validator.body.id
}

resource "aws_api_gateway_integration" "events_post" {
  rest_api_id             = aws_api_gateway_rest_api.cloudpulse.id
  resource_id             = aws_api_gateway_resource.events.id
  http_method             = aws_api_gateway_method.events_post.http_method
  integration_http_method = "POST"           # Lambda invoke is always POST
  type                    = "AWS_PROXY"      # proxy mode — full event passed to Lambda
  uri                     = aws_lambda_alias.ingest_live.invoke_arn
}

# --- OPTIONS /events (CORS preflight — no auth) ---

resource "aws_api_gateway_method" "events_options" {
  rest_api_id   = aws_api_gateway_rest_api.cloudpulse.id
  resource_id   = aws_api_gateway_resource.events.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "events_options" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.events_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "events_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.events_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "events_options" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.events.id
  http_method = aws_api_gateway_method.events_options.http_method
  status_code = aws_api_gateway_method_response.events_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# ============================================================
# /events/batch resource
# ============================================================

resource "aws_api_gateway_resource" "events_batch" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  parent_id   = aws_api_gateway_resource.events.id
  path_part   = "batch"
}

# --- POST /events/batch ---

resource "aws_api_gateway_method" "events_batch_post" {
  rest_api_id          = aws_api_gateway_rest_api.cloudpulse.id
  resource_id          = aws_api_gateway_resource.events_batch.id
  http_method          = "POST"
  authorization        = "COGNITO_USER_POOLS"
  authorizer_id        = aws_api_gateway_authorizer.cognito.id
  request_validator_id = aws_api_gateway_request_validator.body.id
}

resource "aws_api_gateway_integration" "events_batch_post" {
  rest_api_id             = aws_api_gateway_rest_api.cloudpulse.id
  resource_id             = aws_api_gateway_resource.events_batch.id
  http_method             = aws_api_gateway_method.events_batch_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_alias.ingest_live.invoke_arn
}

# --- OPTIONS /events/batch ---

resource "aws_api_gateway_method" "events_batch_options" {
  rest_api_id   = aws_api_gateway_rest_api.cloudpulse.id
  resource_id   = aws_api_gateway_resource.events_batch.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "events_batch_options" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.events_batch.id
  http_method = aws_api_gateway_method.events_batch_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "events_batch_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.events_batch.id
  http_method = aws_api_gateway_method.events_batch_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "events_batch_options" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.events_batch.id
  http_method = aws_api_gateway_method.events_batch_options.http_method
  status_code = aws_api_gateway_method_response.events_batch_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# ============================================================
# /query resource
# ============================================================

resource "aws_api_gateway_resource" "query" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  parent_id   = aws_api_gateway_rest_api.cloudpulse.root_resource_id
  path_part   = "query"
}

# --- GET /query ---

resource "aws_api_gateway_method" "query_get" {
  rest_api_id   = aws_api_gateway_rest_api.cloudpulse.id
  resource_id   = aws_api_gateway_resource.query.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

  # Declare query-string params so API GW passes them through to Lambda
  request_parameters = {
    "method.request.querystring.query_type" = true    # required
    "method.request.querystring.date_from"  = true    # required
    "method.request.querystring.date_to"    = true    # required
    "method.request.querystring.event_type" = false   # optional
    "method.request.querystring.limit"      = false   # optional
  }
}

resource "aws_api_gateway_integration" "query_get" {
  rest_api_id             = aws_api_gateway_rest_api.cloudpulse.id
  resource_id             = aws_api_gateway_resource.query.id
  http_method             = aws_api_gateway_method.query_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_alias.query_live.invoke_arn
}

# --- OPTIONS /query ---

resource "aws_api_gateway_method" "query_options" {
  rest_api_id   = aws_api_gateway_rest_api.cloudpulse.id
  resource_id   = aws_api_gateway_resource.query.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "query_options" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.query.id
  http_method = aws_api_gateway_method.query_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "query_options_200" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.query.id
  http_method = aws_api_gateway_method.query_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "query_options" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id
  resource_id = aws_api_gateway_resource.query.id
  http_method = aws_api_gateway_method.query_options.http_method
  status_code = aws_api_gateway_method_response.query_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# ============================================================
# Deployment + Stage
# ============================================================

# A new deployment is triggered whenever any method or integration changes.
# The triggers map ensures Terraform detects changes across all resources.

resource "aws_api_gateway_deployment" "cloudpulse" {
  rest_api_id = aws_api_gateway_rest_api.cloudpulse.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.events.id,
      aws_api_gateway_resource.events_batch.id,
      aws_api_gateway_resource.query.id,
      aws_api_gateway_method.events_post.id,
      aws_api_gateway_method.events_batch_post.id,
      aws_api_gateway_method.query_get.id,
      aws_api_gateway_integration.events_post.id,
      aws_api_gateway_integration.events_batch_post.id,
      aws_api_gateway_integration.query_get.id,
      aws_api_gateway_authorizer.cognito.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.events_post,
    aws_api_gateway_integration.events_batch_post,
    aws_api_gateway_integration.query_get,
    aws_api_gateway_integration.events_options,
    aws_api_gateway_integration.events_batch_options,
    aws_api_gateway_integration.query_options,
  ]
}

# Sets the CloudWatch Logs role ARN at the account level — required
# for access_log_settings to work on any API Gateway stage in this account.
resource "aws_api_gateway_account" "cloudpulse" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch.arn
}

resource "aws_api_gateway_stage" "cloudpulse" {
  rest_api_id   = aws_api_gateway_rest_api.cloudpulse.id
  deployment_id = aws_api_gateway_deployment.cloudpulse.id
  stage_name    = var.api_stage

  depends_on = [aws_api_gateway_account.cloudpulse]

  # Structured access logs to CloudWatch
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      caller         = "$context.identity.caller"
      user           = "$context.identity.user"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
      responseLatency    = "$context.responseLatency"
      errorMessage       = "$context.error.message"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${local.name_prefix}-access"
  retention_in_days = var.log_retention_days
}

# ============================================================
# Usage plan + throttling
# ============================================================

resource "aws_api_gateway_usage_plan" "cloudpulse" {
  name        = "${local.name_prefix}-usage-plan"
  description = "Free-tier guard: throttles requests to protect Lambda concurrency"

  api_stages {
    api_id = aws_api_gateway_rest_api.cloudpulse.id
    stage  = aws_api_gateway_stage.cloudpulse.stage_name
  }

  throttle_settings {
    rate_limit  = var.api_throttle_rate    # req/s sustained
    burst_limit = var.api_throttle_burst   # req/s burst
  }
}
