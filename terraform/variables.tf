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

variable "schedule_timezone" {
  description = "IANA timezone for the schedule"
  type        = string
  default     = "America/Denver"
}

variable "fargate_cpu" {
  description = "Fargate task CPU units (1 vCPU = 1024). Must be one of: 256, 512, 1024, 2048, 4096, 8192, 16384"
  type        = number
  default     = 1024 # 1 vCPU — tabular data only
}

variable "fargate_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 4096 # 4 GB
}

variable "fargate_ephemeral_storage_gib" {
  description = "Fargate ephemeral storage in GiB (min 21, max 200)."
  type        = number
  default     = 21 # minimum — SNOTEL archive is small
}

variable "container_cores" {
  description = "Number of parallel download workers passed to the R pipeline (CORES env var)"
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 90
}
