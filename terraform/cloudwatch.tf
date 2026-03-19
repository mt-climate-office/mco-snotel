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

# Alert when a task exits with a non-zero status.
# ECS Container Insights must be enabled on the cluster (set in ecs.tf).
resource "aws_cloudwatch_metric_alarm" "task_failures" {
  alarm_name          = "${var.project_name}-task-failures"
  alarm_description   = "Fires when the SNOTEL pipeline Fargate task fails"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "TaskSetTaskCount"
  statistic           = "Sum"
  comparison_operator = "LessThanThreshold"
  threshold           = 0 # placeholder — wire to an SNS topic to get notified
  evaluation_periods  = 1
  period              = 86400
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.pipeline.name
  }

  tags = local.common_tags
}
