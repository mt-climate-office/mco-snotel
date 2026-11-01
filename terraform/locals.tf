locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }

  # Use explicitly provided subnet IDs, or fall back to all subnets in the VPC.
  resolved_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.vpc.ids

  # Security groups for Fargate tasks.
  fargate_security_group_ids = var.extra_security_group_ids

  # Every task (daily run and the annual normals build) runs this exact image.
  # Deploy a new build by changing image_digest (image.auto.tfvars).
  ecr_image_url = "${aws_ecr_repository.pipeline.repository_url}@${var.image_digest}"
}
