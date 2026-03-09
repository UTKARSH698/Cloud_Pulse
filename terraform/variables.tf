# ============================================================
# terraform/variables.tf
#
# All tunable inputs in one place.
# Override via terraform.tfvars or -var flags in CI/CD.
# ============================================================

# ------------------------------------------------------------
# Project identity
# ------------------------------------------------------------

variable "project" {
  description = "Project name — used as a prefix for every resource name."
  type        = string
  default     = "cloudpulse"
}

variable "environment" {
  description = "Deployment environment. Controls resource naming and log retention."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

# ------------------------------------------------------------
# S3
# ------------------------------------------------------------

variable "s3_event_prefix" {
  description = "Top-level S3 prefix for raw analytics events (Hive-partitioned)."
  type        = string
  default     = "events"
}

variable "s3_lifecycle_days" {
  description = "Days before raw event objects transition to S3-IA (cost saving)."
  type        = number
  default     = 30

  validation {
    condition     = var.s3_lifecycle_days >= 30
    error_message = "Minimum lifecycle transition is 30 days (AWS S3-IA requirement)."
  }
}

# ------------------------------------------------------------
# Lambda
# ------------------------------------------------------------

variable "lambda_runtime" {
  description = "Python runtime for all Lambda functions."
  type        = string
  default     = "python3.11"
}

variable "lambda_timeout_ingest" {
  description = "Ingest Lambda timeout in seconds. Keep low — should finish in < 3 s."
  type        = number
  default     = 15
}

variable "lambda_timeout_query" {
  description = "Query Lambda timeout in seconds. Athena polls add latency; 29 s is the API GW limit."
  type        = number
  default     = 29
}

variable "lambda_memory_mb" {
  description = "Memory allocated to each Lambda function (MB). 128 MB is free-tier safe."
  type        = number
  default     = 128
}

# ------------------------------------------------------------
# API Gateway
# ------------------------------------------------------------

variable "api_stage" {
  description = "API Gateway stage name (appears in the invoke URL)."
  type        = string
  default     = "v1"
}

variable "api_throttle_rate" {
  description = "API Gateway steady-state request rate limit (requests/second)."
  type        = number
  default     = 10
}

variable "api_throttle_burst" {
  description = "API Gateway burst request limit."
  type        = number
  default     = 20
}

# ------------------------------------------------------------
# Cognito
# ------------------------------------------------------------

variable "cognito_token_validity_hours" {
  description = "Access token validity period in hours."
  type        = number
  default     = 1
}

# ------------------------------------------------------------
# Glue
# ------------------------------------------------------------

variable "glue_crawler_schedule" {
  description = "Cron schedule for the Glue Crawler (UTC). Default: every 6 hours."
  type        = string
  default     = "cron(0 */6 * * ? *)"
}

# ------------------------------------------------------------
# Athena
# ------------------------------------------------------------

variable "athena_workgroup" {
  description = "Athena workgroup name."
  type        = string
  default     = "cloudpulse"
}

variable "athena_bytes_scanned_cutoff" {
  description = "Athena per-query data-scanned limit (bytes). Protects against runaway queries on free tier. Default 100 MB."
  type        = number
  default     = 104857600  # 100 MB
}

# ------------------------------------------------------------
# CloudWatch
# ------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log group retention period in days."
  type        = number
  default     = 7   # minimum on free tier

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a value supported by CloudWatch (e.g. 7, 14, 30)."
  }
}

# ------------------------------------------------------------
# Tagging
# ------------------------------------------------------------

variable "tags" {
  description = "Tags applied to every resource. Merge with local defaults in each module."
  type        = map(string)
  default     = {}
}
