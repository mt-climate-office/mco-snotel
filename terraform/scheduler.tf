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

  schedule_expression          = var.schedule_time     # cron(0 10 * * ? *)
  schedule_expression_timezone = var.schedule_timezone # America/Denver

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

# The yearly normals build: the same task, running normals-annual.R instead of
# the image's default mco-snotel.R. It refetches every station's record,
# freezes the year before, and builds the new water year's normals.
resource "aws_scheduler_schedule" "normals_annual" {
  name       = "${var.project_name}-normals-annual"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.normals_schedule  # cron(0 14 1 10 ? *)
  schedule_expression_timezone = var.schedule_timezone # America/Denver

  target {
    arn      = aws_ecs_cluster.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn

    # RunTask overrides.
    input = jsonencode({
      containerOverrides = [{
        name    = "snotel-pipeline"
        command = ["normals-annual.R"]
      }]
    })

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
      maximum_retry_attempts       = 1
      maximum_event_age_in_seconds = 3600
    }
  }
}

# Layout v1 dual-write: the same task and image, writing the v1 layout
# (config/layout-v1.yml) after the v0 run. It reads and writes only v1 keys and
# cache/v1/. Removed when v0 is retired; set var.v1_writer = false to stop it.
resource "aws_scheduler_schedule" "daily_v1" {
  count      = var.v1_writer ? 1 : 0
  name       = "${var.project_name}-daily-v1"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.v1_schedule_time
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = aws_ecs_cluster.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      containerOverrides = [{
        name        = "snotel-pipeline"
        environment = [{ name = "LAYOUT_CONFIG", value = "config/layout-v1.yml" }]
      }]
    })

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
      maximum_retry_attempts       = 1
      maximum_event_age_in_seconds = 3600
    }
  }
}
