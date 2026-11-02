variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS SSO profile name (as in ~/.aws/config)"
  type        = string
  default     = "mco"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "image_digest" {
  description = "Digest (sha256:...) of the ECR image every task runs. Set in image.auto.tfvars; tag the deployed image prod-<date> so the lifecycle policy keeps it."
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be a full sha256:<64 hex> digest, not a tag."
  }
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "mco-snotel"
}

variable "vpc_id" {
  description = "Existing VPC ID in which to place Fargate tasks"
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Subnet IDs for Fargate tasks.
    Must be public subnets with an Internet Gateway route when assign_public_ip = true.
    Leave empty to use all subnets in the VPC (discovered automatically).
  EOT
  type        = list(string)
  default     = []
}

variable "extra_security_group_ids" {
  description = "Existing security group IDs to attach to Fargate tasks"
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = <<-EOT
    Assign a public IP to Fargate tasks.
    Required when tasks run in public subnets and need internet access (NRCS/SNOTEL downloads).
    Set to false if tasks run in private subnets behind a NAT gateway.
  EOT
  type        = bool
  default     = true
}

variable "s3_bucket_name" {
  description = "S3 bucket name for all pipeline inputs and outputs"
  type        = string
  default     = "mco-snotel"
}

variable "schedule_time" {
  description = "Cron expression for the daily run, evaluated in schedule_timezone"
  type        = string
  default     = "cron(0 10 * * ? *)" # 10:00 AM daily — SNOTEL obs finalize by ~8 AM MST
}

variable "normals_schedule" {
  description = "Cron expression for the yearly normals build, evaluated in schedule_timezone"
  type        = string
  default     = "cron(0 14 1 10 ? *)" # Oct 1, 2 PM: after the daily run ingests Sep 30
}

variable "schedule_timezone" {
  description = "IANA timezone for the schedule"
  type        = string
  default     = "America/Denver"
}

variable "fargate_cpu" {
  description = "Fargate task CPU units (1 vCPU = 1024). Must be one of: 256, 512, 1024, 2048, 4096, 8192, 16384"
  type        = number
  default     = 4096 # 4 vCPU — parallel plotting
}

variable "fargate_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 16384 # 16 GB — the archive is rewritten in memory
}

variable "fargate_ephemeral_storage_gib" {
  description = "Fargate ephemeral storage in GiB (min 21, max 200)."
  type        = number
  default     = 21 # minimum — SNOTEL archive is small
}

variable "container_cores" {
  description = "Plotting and fitting workers passed to the R pipeline (CORES env var)"
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 90
}

# Shadow runs (shadow.tf)

variable "shadow_s3_bucket_name" {
  description = "Private test bucket for shadow runs"
  type        = string
  default     = "mco-snotel-test"
}

variable "shadow_image_digest" {
  description = "Image digest (sha256:...) in this project's ECR repository for the shadow task. Null runs the production image."
  type        = string
  default     = null

  validation {
    condition     = var.shadow_image_digest == null || can(regex("^sha256:[0-9a-f]{64}$", var.shadow_image_digest))
    error_message = "shadow_image_digest must be null or sha256:<64 hex digits>."
  }
}

variable "shadow_schedule_time" {
  description = "Cron expression for the shadow run, evaluated in schedule_timezone (the schedule is created DISABLED)"
  type        = string
  default     = "cron(0 13 * * ? *)"
}

variable "shadow_local_role_name" {
  description = "Name of the role assumed for local shadow work (AWS CLI profile in README). IAM role names are account-wide, so each project has its own."
  type        = string
  default     = "mco-shadow-snotel"
}

variable "shadow_trusted_role_arns" {
  description = "Role ARN patterns (ArnLike) allowed to assume the local shadow role: the account's SSO admin permission set"
  type        = list(string)
  default     = ["arn:aws:iam::202533506375:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_SA-MCO-Admins_*"]
}

# Alerts (alerts.tf, freshness.tf)

variable "alert_email" {
  description = "Optional email address subscribed directly to the <project>-alerts SNS topic (null: none; alerts reach Listmonk through mesonet-alerts). AWS emails it a confirmation link that must be clicked."
  type        = string
  default     = null

  validation {
    condition     = var.alert_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "freshness_schedule" {
  description = "Cron expression for the freshness check of latest/manifest.json, evaluated in schedule_timezone"
  type        = string
  default     = "cron(0 13 * * ? *)" # 1 PM, three hours after the daily run starts
}

variable "freshness_max_age_days" {
  description = "Alert when latest/manifest.json's date is more than this many days before today (America/Denver)"
  type        = number
  default     = 2
}
