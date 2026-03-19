# EventBridge Scheduler fires at 10:00 AM America/Denver (Mountain Time) every day.
# SNOTEL observations typically finalize by ~8 AM MST; running at 10 AM gives
# the network time to publish before we fetch.
# The scheduler honors DST automatically.
resource "aws_scheduler_schedule" "daily" {
  name       = "${var.project_name}-daily"
  group_name = "default"

  flexible_time_window {
    mode = "OFF" # start at exactly the scheduled time
  }

  schedule_expression          = var.schedule_time      # cron(0 10 * * ? *)
  schedule_expression_timezone = var.schedule_timezone  # America/Denver

  target {
    arn      = aws_ecs_cluster.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.pipeline.arn
      launch_type         = "FARGATE"
      task_count          = 1

      network_configuration {
        assign_public_ip = var.assign_public_ip
        subnets          = local.resolved_subnet_ids
        security_groups  = local.fargate_security_group_ids
      }
    }

    retry_policy {
      maximum_retry_attempts       = 1    # retry once if the task fails
      maximum_event_age_in_seconds = 3600 # drop if not started within 1 h
    }
  }
}
