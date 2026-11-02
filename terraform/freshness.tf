# Freshness check: a small Lambda, run daily by EventBridge Scheduler, reads
# latest/manifest.json and alerts (alerts.tf topic) when its "date" is more
# than freshness_max_age_days before today (America/Denver) or the file is
# missing. Catches a run that never started or stopped without an error event.
# The source, lambda/freshness.py, is kept identical in mco-snodas and
# mco-snotel.
#
# Run by hand:
#   aws lambda invoke --function-name mco-snotel-freshness /dev/stdout

locals {
  freshness_name = "${var.project_name}-freshness"
  freshness_key  = "latest/manifest.json"
}

# Built under .terraform/ (git-ignored).
data "archive_file" "freshness" {
  type        = "zip"
  source_file = "${path.module}/lambda/freshness.py"
  output_path = "${path.module}/.terraform/build/freshness.zip"
}

resource "aws_lambda_function" "freshness" {
  function_name    = local.freshness_name
  description      = "Alert when s3://${var.s3_bucket_name}/${local.freshness_key} is stale or missing"
  role             = aws_iam_role.freshness.arn
  runtime          = "python3.12"
  handler          = "freshness.handler"
  filename         = data.archive_file.freshness.output_path
  source_code_hash = data.archive_file.freshness.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      PROJECT      = var.project_name
      BUCKET       = var.s3_bucket_name
      KEY          = local.freshness_key
      MAX_AGE_DAYS = tostring(var.freshness_max_age_days)
      TOPIC_ARN    = aws_sns_topic.alerts.arn
      LOG_GROUP    = aws_cloudwatch_log_group.pipeline.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.freshness]

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "freshness" {
  name              = "/aws/lambda/${local.freshness_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags

  lifecycle {
    # An org-level policy sets the KMS key and may lengthen retention.
    ignore_changes = [kms_key_id, retention_in_days]
  }
}

# Lambda role: read the one manifest, publish to the topic, write its logs.
resource "aws_iam_role" "freshness" {
  name = local.freshness_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "freshness" {
  name = local.freshness_name
  role = aws_iam_role.freshness.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadManifest"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.outputs.arn}/${local.freshness_key}"]
      },
      {
        Sid      = "PublishAlert"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts.arn]
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.freshness.arn}:*"]
      },
    ]
  })
}

# Daily at freshness_schedule (13:00), after the 10:00 run has published.
resource "aws_scheduler_schedule" "freshness" {
  name       = local.freshness_name
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.freshness_schedule
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = aws_lambda_function.freshness.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }
  }
}

resource "aws_iam_role_policy" "scheduler_invoke_freshness" {
  name = "${var.project_name}-invoke-freshness"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeFreshness"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.freshness.arn]
    }]
  })
}

# The check itself failing (it alerts only when it runs to the end).
resource "aws_cloudwatch_metric_alarm" "freshness_errors" {
  alarm_name          = "${var.project_name}-freshness-errors"
  alarm_description   = "The ${local.freshness_name} Lambda failed, so the freshness check did not run"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 3600
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.freshness.function_name
  }

  tags = local.common_tags
}
