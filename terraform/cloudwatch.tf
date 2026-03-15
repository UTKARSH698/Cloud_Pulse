# ============================================================
# terraform/cloudwatch.tf
#
# CloudWatch alarms + dashboard for CloudPulse observability.
#
# Alarms (SNS not wired — free tier avoids SNS charges)
# -------------------------------------------------------
#   ingest-errors      — Lambda errors > 0 in any 5-min window
#   ingest-throttles   — Lambda throttles > 0
#   query-errors       — Lambda errors > 0
#   query-duration     — query Lambda p99 > 25 s (near the 29 s timeout)
#   api-5xx            — API Gateway 5xx count > 5 in 5 min
#
# Dashboard
# ---------
# One CloudWatch dashboard with 8 widgets covering:
#   - Lambda invocations, errors, duration (both functions)
#   - API Gateway request count + latency + error rates
#   - Athena bytes scanned per query (cost awareness)
# ============================================================

# ------------------------------------------------------------
# Alarms — Ingest Lambda
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ingest_errors" {
  alarm_name          = "${local.name_prefix}-ingest-errors"
  alarm_description   = "Ingest Lambda threw an unhandled exception"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300   # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.ingest.function_name
    Resource     = "${aws_lambda_function.ingest.function_name}:live"
  }
}

resource "aws_cloudwatch_metric_alarm" "ingest_throttles" {
  alarm_name          = "${local.name_prefix}-ingest-throttles"
  alarm_description   = "Ingest Lambda is being throttled — concurrency limit hit"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.ingest.function_name
    Resource     = "${aws_lambda_function.ingest.function_name}:live"
  }
}

# ------------------------------------------------------------
# Alarms — Query Lambda
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "query_errors" {
  alarm_name          = "${local.name_prefix}-query-errors"
  alarm_description   = "Query Lambda threw an unhandled exception"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.query.function_name
    Resource     = "${aws_lambda_function.query.function_name}:live"
  }
}

resource "aws_cloudwatch_metric_alarm" "query_duration_p99" {
  alarm_name          = "${local.name_prefix}-query-duration-p99"
  alarm_description   = "Query Lambda p99 duration > 25 s — approaching 29 s API GW timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 25000   # milliseconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.query.function_name
    Resource     = "${aws_lambda_function.query.function_name}:live"
  }
}

# ------------------------------------------------------------
# Alarm — API Gateway 5xx
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name_prefix}-api-5xx"
  alarm_description   = "API Gateway returned 5+ server errors in a 5-minute window"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName  = aws_api_gateway_rest_api.cloudpulse.name
    Stage    = aws_api_gateway_stage.cloudpulse.stage_name
  }
}

# ------------------------------------------------------------
# Alarms — Stream Processor + Realtime Lambdas
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "stream_processor_errors" {
  alarm_name          = "${local.name_prefix}-stream-processor-errors"
  alarm_description   = "Stream Processor Lambda error — Kinesis records may not be aggregated"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.stream_processor.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age" {
  alarm_name          = "${local.name_prefix}-kinesis-iterator-age"
  alarm_description   = "Kinesis consumer is falling behind — stream processor may be throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  namespace           = "AWS/Kinesis"
  period              = 300
  statistic           = "Maximum"
  threshold           = 60000   # 60 seconds behind is concerning
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = aws_kinesis_stream.events.name
  }
}

# ------------------------------------------------------------
# Alarms — Worker Lambda + SQS DLQ
# ------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "worker_errors" {
  alarm_name          = "${local.name_prefix}-worker-errors"
  alarm_description   = "Worker Lambda error — SQS messages may not be landing in S3"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.worker.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "sqs_dlq_depth" {
  alarm_name          = "${local.name_prefix}-sqs-dlq-depth"
  alarm_description   = "SQS DLQ has messages — events failed to land in S3 after 3 retries"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.events_dlq.name
  }
}

# ------------------------------------------------------------
# CloudWatch Dashboard
# ------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "cloudpulse" {
  dashboard_name = local.name_prefix

  dashboard_body = jsonencode({
    widgets = [

      # ── Row 1: Ingest Lambda ─────────────────────────────────

      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Ingest — Invocations & Errors"
          region = local.region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.ingest.function_name, "Resource", "${aws_lambda_function.ingest.function_name}:live", { stat = "Sum", color = "#2ca02c", label = "Invocations" }],
            ["AWS/Lambda", "Errors",      "FunctionName", aws_lambda_function.ingest.function_name, "Resource", "${aws_lambda_function.ingest.function_name}:live", { stat = "Sum", color = "#d62728", label = "Errors" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Ingest — Duration (ms)"
          region = local.region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.ingest.function_name, "Resource", "${aws_lambda_function.ingest.function_name}:live", { stat = "p50",  label = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.ingest.function_name, "Resource", "${aws_lambda_function.ingest.function_name}:live", { stat = "p99",  label = "p99", color = "#ff7f0e" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Ingest — Throttles"
          region = local.region
          metrics = [
            ["AWS/Lambda", "Throttles", "FunctionName", aws_lambda_function.ingest.function_name, "Resource", "${aws_lambda_function.ingest.function_name}:live", { stat = "Sum", color = "#9467bd" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      # ── Row 2: Query Lambda ──────────────────────────────────

      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Query — Invocations & Errors"
          region = local.region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.query.function_name, "Resource", "${aws_lambda_function.query.function_name}:live", { stat = "Sum", color = "#1f77b4", label = "Invocations" }],
            ["AWS/Lambda", "Errors",      "FunctionName", aws_lambda_function.query.function_name, "Resource", "${aws_lambda_function.query.function_name}:live", { stat = "Sum", color = "#d62728", label = "Errors" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Query — Duration p50 / p99 (ms)"
          region = local.region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.query.function_name, "Resource", "${aws_lambda_function.query.function_name}:live", { stat = "p50", label = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.query.function_name, "Resource", "${aws_lambda_function.query.function_name}:live", { stat = "p99", label = "p99", color = "#ff7f0e" }],
            [{ expression = "29000", label = "Timeout limit (29 s)", color = "#d62728" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      # ── Row 3: API Gateway ───────────────────────────────────

      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "API Gateway — Request Count"
          region = local.region
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", aws_api_gateway_rest_api.cloudpulse.name, "Stage", aws_api_gateway_stage.cloudpulse.stage_name, { stat = "Sum", color = "#2ca02c" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "API Gateway — Latency p50 / p99 (ms)"
          region = local.region
          metrics = [
            ["AWS/ApiGateway", "Latency",            "ApiName", aws_api_gateway_rest_api.cloudpulse.name, "Stage", aws_api_gateway_stage.cloudpulse.stage_name, { stat = "p50", label = "p50" }],
            ["AWS/ApiGateway", "IntegrationLatency", "ApiName", aws_api_gateway_rest_api.cloudpulse.name, "Stage", aws_api_gateway_stage.cloudpulse.stage_name, { stat = "p99", label = "Integration p99", color = "#ff7f0e" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "API Gateway — 4xx / 5xx Errors"
          region = local.region
          metrics = [
            ["AWS/ApiGateway", "4XXError", "ApiName", aws_api_gateway_rest_api.cloudpulse.name, "Stage", aws_api_gateway_stage.cloudpulse.stage_name, { stat = "Sum", color = "#ff7f0e", label = "4xx" }],
            ["AWS/ApiGateway", "5XXError", "ApiName", aws_api_gateway_rest_api.cloudpulse.name, "Stage", aws_api_gateway_stage.cloudpulse.stage_name, { stat = "Sum", color = "#d62728", label = "5xx" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      # ── Row 4: Athena cost ───────────────────────────────────

      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Athena — Bytes Scanned per Query (cost awareness)"
          region = local.region
          metrics = [
            ["AWS/Athena", "ProcessedBytes", "WorkGroup", var.athena_workgroup, { stat = "Maximum", label = "Max scanned (bytes)", color = "#e377c2" }],
            ["AWS/Athena", "ProcessedBytes", "WorkGroup", var.athena_workgroup, { stat = "Average", label = "Avg scanned (bytes)", color = "#7f7f7f" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Athena — Query Execution Time (ms)"
          region = local.region
          metrics = [
            ["AWS/Athena", "QueryExecutionTime", "WorkGroup", var.athena_workgroup, { stat = "p50",  label = "p50" }],
            ["AWS/Athena", "QueryExecutionTime", "WorkGroup", var.athena_workgroup, { stat = "p99",  label = "p99", color = "#ff7f0e" }],
          ]
          view   = "timeSeries"
          period = 300
        }
      },

    ]
  })
}
