# Shadow runs: the pipeline against a private copy of the bucket, to show a
# change leaves the outputs as they are before it reaches production.
#
#   - var.shadow_s3_bucket_name: the test bucket. Private, versioned, and
#     noncurrent versions expire after 30 days.
#   - aws_iam_role.shadow_task: the shadow task's role.
#   - aws_iam_role.shadow_local: the same permissions, assumed from the SSO
#     admin role for local runs and for scripts/parity/seed.sh.
#     Both read the production bucket, read and write the test bucket, and are
#     explicitly denied writes and deletes in the production bucket.
#   - aws_ecs_task_definition.shadow: the daily task on Fargate Spot with
#     S3_BUCKET set to the test bucket.
#   - aws_scheduler_schedule.shadow: 13:00 daily, created DISABLED.
#
# scripts/parity/seed.sh copies a date's inputs from production into the test
# bucket; scripts/parity/diff.R compares the outputs.

locals {
  shadow_tags = merge(local.common_tags, { Purpose = "shadow" })

  # The candidate image by digest, or the production image when unset.
  shadow_image_url = var.shadow_image_digest == null ? local.ecr_image_url : "${aws_ecr_repository.pipeline.repository_url}@${var.shadow_image_digest}"
}

# ── Test bucket ───────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "shadow" {
  bucket = var.shadow_s3_bucket_name
  tags   = local.shadow_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "shadow" {
  bucket = aws_s3_bucket.shadow.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "shadow" {
  bucket = aws_s3_bucket.shadow.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "shadow" {
  bucket = aws_s3_bucket.shadow.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "shadow" {
  bucket = aws_s3_bucket.shadow.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.shadow]
}

# ── S3 permissions shared by the shadow task role and the local role ─────────

data "aws_iam_policy_document" "shadow_s3" {
  statement {
    sid       = "ReadProductionList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.outputs.arn]
  }

  statement {
    sid    = "ReadProductionObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${aws_s3_bucket.outputs.arn}/*"]
  }

  statement {
    sid       = "ReadWriteTestList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.shadow.arn]
  }

  statement {
    sid    = "ReadWriteTestObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging",
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.shadow.arn}/*"]
  }

  # Belt and braces: nothing granted elsewhere can let a shadow write to or
  # delete from production.
  statement {
    sid    = "DenyProductionWrites"
    effect = "Deny"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:PutObjectVersionAcl",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["${aws_s3_bucket.outputs.arn}/*"]
  }
}

# ── Shadow ECS task role ──────────────────────────────────────────────────────

resource "aws_iam_role" "shadow_task" {
  name = "${var.project_name}-shadow-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.shadow_tags
}

resource "aws_iam_role_policy" "shadow_task_s3" {
  name   = "${var.project_name}-shadow-s3"
  role   = aws_iam_role.shadow_task.id
  policy = data.aws_iam_policy_document.shadow_s3.json
}

# ── Local shadow role (AWS CLI profile, see README "Shadow runs") ─────────────

resource "aws_iam_role" "shadow_local" {
  name                 = var.shadow_local_role_name
  max_session_duration = 43200

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" }
      Condition = {
        ArnLike = { "aws:PrincipalArn" = var.shadow_trusted_role_arns }
      }
    }]
  })

  tags = local.shadow_tags
}

resource "aws_iam_role_policy" "shadow_local_s3" {
  name   = "${var.project_name}-shadow-s3"
  role   = aws_iam_role.shadow_local.id
  policy = data.aws_iam_policy_document.shadow_s3.json
}

# ── Shadow task definition (Fargate Spot) ─────────────────────────────────────

resource "aws_ecs_task_definition" "shadow" {
  family                   = "${var.project_name}-shadow"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.shadow_task.arn

  ephemeral_storage {
    size_in_gib = var.fargate_ephemeral_storage_gib
  }

  # As the daily task (ecs.tf), apart from the image, bucket and log prefix.
  container_definitions = jsonencode([
    {
      name      = "snotel-pipeline"
      image     = local.shadow_image_url
      essential = true

      environment = [
        { name = "TZ", value = "America/Denver" },
        { name = "S3_BUCKET", value = aws_s3_bucket.shadow.bucket },
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
          "awslogs-stream-prefix" = "shadow"
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

  tags = local.shadow_tags
}

# ── Shadow schedule (created disabled) ────────────────────────────────────────

resource "aws_iam_role" "shadow_scheduler" {
  name = "${var.project_name}-shadow-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })

  tags = local.shadow_tags
}

resource "aws_iam_role_policy" "shadow_scheduler_run_task" {
  name = "${var.project_name}-shadow-run-task"
  role = aws_iam_role.shadow_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunShadowTask"
        Effect = "Allow"
        Action = ["ecs:RunTask"]
        # Any revision of the shadow family.
        Resource = ["${aws_ecs_task_definition.shadow.arn_without_revision}:*"]
      },
      {
        Sid    = "PassRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.task_execution.arn,
          aws_iam_role.shadow_task.arn,
        ]
      },
    ]
  })
}

resource "aws_scheduler_schedule" "shadow" {
  name       = "${var.project_name}-shadow"
  group_name = "default"
  state      = "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.shadow_schedule_time
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = aws_ecs_cluster.pipeline.arn
    role_arn = aws_iam_role.shadow_scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.shadow.arn
      task_count          = 1

      capacity_provider_strategy {
        capacity_provider = "FARGATE_SPOT"
        weight            = 1
      }

      network_configuration {
        assign_public_ip = var.assign_public_ip
        subnets          = local.resolved_subnet_ids
        security_groups  = local.fargate_security_group_ids
      }
    }

    retry_policy {
      maximum_retry_attempts       = 0
      maximum_event_age_in_seconds = 3600
    }
  }
}
