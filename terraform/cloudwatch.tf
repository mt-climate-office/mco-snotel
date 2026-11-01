resource "aws_cloudwatch_log_group" "pipeline" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags

  lifecycle {
    # The org-level policy automatically applies a KMS key and may set a longer
    # retention. Ignore both so Terraform doesn't fight account-wide controls.
    ignore_changes = [kms_key_id, retention_in_days]
  }
}

# Per-station plot failures in the daily run. stage_viz catches an error in
# one station's plot, logs it and goes on, so the task still exits 0:
#   "  <period>: <n> stations in <m> min; <k> failed"   (k > 0)
# "0 failed" is the normal line, so this needs a regex. Failures that stop
# the task ("Plots failed for", "Outlook failed for", AWDB request failures)
# are left to the ECS rule in alerts.tf. The log group also holds the yearly
# normals-annual.R run.
locals {
  daily_error_metric = {
    namespace = "MCO/${var.project_name}"
    name      = "DailyErrors"
  }
}

resource "aws_cloudwatch_log_metric_filter" "plot_errors" {
  name           = "${var.project_name}-plot-errors"
  log_group_name = aws_cloudwatch_log_group.pipeline.name
  pattern        = "%min; [1-9][0-9]* failed%"

  metric_transformation {
    namespace     = local.daily_error_metric.namespace
    name          = local.daily_error_metric.name
    value         = "1"
    default_value = "0"
  }
}

# Hourly window, so an error on consecutive days alarms (and emails) each day
# rather than holding one 24-hour alarm open.
resource "aws_cloudwatch_metric_alarm" "daily_errors" {
  alarm_name          = "${var.project_name}-daily-errors"
  alarm_description   = "The ${var.project_name} run logged station plots that failed (it exits 0 for these). Search the log group for: failed."
  namespace           = local.daily_error_metric.namespace
  metric_name         = local.daily_error_metric.name
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 3600
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}
