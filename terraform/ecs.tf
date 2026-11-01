resource "aws_ecs_cluster" "pipeline" {
  name = var.project_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "pipeline" {
  cluster_name       = aws_ecs_cluster.pipeline.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 100
    base              = 1
  }
}

resource "aws_ecs_task_definition" "pipeline" {
  # Keep each superseded revision registered, so a rollback can point the
  # schedules back at the previous revision (and its pinned digest).
  skip_destroy = true

  family                   = var.project_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  ephemeral_storage {
    size_in_gib = var.fargate_ephemeral_storage_gib
  }

  container_definitions = jsonencode([
    {
      name      = "snotel-pipeline"
      image     = local.ecr_image_url
      essential = true

      environment = [
        { name = "TZ", value = "America/Denver" },
        { name = "S3_BUCKET", value = var.s3_bucket_name },
        { name = "WORK_DIR", value = "/tmp/snotel" },
        { name = "KEEP_LOCAL", value = "FALSE" },
        { name = "CORES", value = tostring(var.container_cores) },
        { name = "CALC_FIGURES", value = "TRUE" },
        { name = "AWS_DEFAULT_REGION", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.pipeline.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "pipeline"
        }
      }

      ulimits = [
        {
          name      = "nofile"
          softLimit = 65536
          hardLimit = 65536
        }
      ]
    }
  ])

  tags = local.common_tags
}
