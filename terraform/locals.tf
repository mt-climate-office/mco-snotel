locals {
  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }

  # The bucket layout the pipeline uses (R/layout.R): its bucket, and keys
  # Terraform needs, from the artifact templates. An artifact is a template
  # string or a map with `template`.
  layout           = yamldecode(file("${path.module}/../config/layout.yml"))
  layout_templates = { for id, a in local.layout.artifacts : id => try(a.template, a) }

  s3_bucket_name        = coalesce(var.s3_bucket_name, local.layout.bucket)
  shadow_s3_bucket_name = coalesce(var.shadow_s3_bucket_name, "${local.layout.bucket}-test")

  # Use explicitly provided subnet IDs, or fall back to all subnets in the VPC.
  resolved_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.vpc.ids

  # Security groups for Fargate tasks.
  fargate_security_group_ids = var.extra_security_group_ids

  # Every task (daily run and the annual normals build) runs this exact image.
  # Deploy a new build by changing image_digest (image.auto.tfvars).
  ecr_image_url = "${aws_ecr_repository.pipeline.repository_url}@${var.image_digest}"
}
