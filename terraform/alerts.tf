# Alerts: one SNS topic, emailed to alert_email. What publishes to it:
#   - an ECS task in the cluster stops with an error (EventBridge rule below);
#   - station plots that failed in the daily log (metric filter + alarm,
#     cloudwatch.tf);
#   - latest/manifest.json is stale or missing at 13:00 (freshness.tf).
# The email subscription must be confirmed from the inbox before any arrive.

locals {
  alerts_log_group_url = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:log-groups/log-group/${replace(aws_cloudwatch_log_group.pipeline.name, "/", "$252F")}"
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  tags = local.common_tags
}

# Alerts are delivered by mesonet-alerts' alarm_format Lambda as Listmonk
# campaigns ("Snow: Pipeline alerts"), which subscribes to this topic itself.
# A direct email subscription is optional, e.g. while that route is down.
resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email == null ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# EventBridge and CloudWatch publish under the topic policy; the freshness
# Lambda publishes under its own role (freshness.tf).
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EventBridgeRules"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = [
              aws_cloudwatch_event_rule.task_failed.arn,
            ]
          }
        }
      },
      {
        Sid       = "CloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${var.aws_region}:${var.aws_account_id}:alarm:${var.project_name}-*"
          }
        }
      },
    ]
  })
}

# ECS task stopped with an error: any container exited non-zero, or the task
# never started (image pull, secrets/logging setup, no free subnet address).
# Covers the daily run and the yearly normals-annual.R run (same task).
resource "aws_cloudwatch_event_rule" "task_failed" {
  name        = "${var.project_name}-task-failed"
  description = "An ${var.project_name} ECS task stopped with an error"

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.pipeline.arn]
      # Shadow tasks (shadow.tf) are tests: their failures do not alert.
      taskDefinitionArn = [{ "anything-but" = { prefix = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:task-definition/${var.project_name}-shadow:" } }]
      lastStatus        = ["STOPPED"]
      "$or" = [
        { containers = { exitCode = [{ "anything-but" = 0 }] } },
        { stopCode = ["TaskFailedToStart"] },
        { stoppedReason = [
          { prefix = "CannotPullContainer" },
          { prefix = "ResourceInitializationError" },
          { wildcard = "*nsufficient*" },
        ] },
      ]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "task_failed" {
  rule = aws_cloudwatch_event_rule.task_failed.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      time       = "$.time"
      task       = "$.detail.taskArn"
      taskDef    = "$.detail.taskDefinitionArn"
      startedBy  = "$.detail.startedBy"
      stopCode   = "$.detail.stopCode"
      reason     = "$.detail.stoppedReason"
      exitCode   = "$.detail.containers[0].exitCode"
      exitReason = "$.detail.containers[0].reason"
    }
    input_template = <<-EOT
      {
        "alert": "${var.project_name}: ECS task stopped with an error",
        "time": "<time>",
        "task_definition": "<taskDef>",
        "started_by": "<startedBy>",
        "exit_code": "<exitCode>",
        "stop_code": "<stopCode>",
        "stopped_reason": "<reason>",
        "container_reason": "<exitReason>",
        "task": "<task>",
        "logs": "${local.alerts_log_group_url} (stream pipeline/snotel-pipeline/ followed by the task ID)"
      }
    EOT
  }
}
