output "s3_bucket_name" {
  description = "S3 bucket for all SNOTEL pipeline inputs and outputs"
  value       = aws_s3_bucket.outputs.bucket
}

output "s3_bucket_url" {
  description = "HTTPS URL of the S3 bucket"
  value       = "https://${aws_s3_bucket.outputs.bucket_regional_domain_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL — use this when tagging/pushing the Docker image"
  value       = aws_ecr_repository.pipeline.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.pipeline.name
}

output "ecs_task_definition_arn" {
  description = "Latest ECS task definition ARN"
  value       = aws_ecs_task_definition.pipeline.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for pipeline runs"
  value       = aws_cloudwatch_log_group.pipeline.name
}

output "scheduler_arn" {
  description = "EventBridge Scheduler ARN (daily trigger)"
  value       = aws_scheduler_schedule.daily.arn
}

output "shadow_s3_bucket_name" {
  description = "Private test bucket for shadow runs"
  value       = aws_s3_bucket.shadow.bucket
}

output "shadow_local_role_arn" {
  description = "Role for local shadow work: role_arn of the AWS CLI shadow profile (README, Shadow runs)"
  value       = aws_iam_role.shadow_local.arn
}

output "shadow_task_definition_arn" {
  description = "Shadow ECS task definition (Fargate Spot, S3_BUCKET = the test bucket)"
  value       = aws_ecs_task_definition.shadow.arn
}

output "shadow_scheduler_arn" {
  description = "Shadow EventBridge schedule (created DISABLED)"
  value       = aws_scheduler_schedule.shadow.arn
}
