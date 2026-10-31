resource "aws_s3_bucket" "outputs" {
  bucket = var.s3_bucket_name
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "outputs" {
  bucket = aws_s3_bucket.outputs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Allow public reads (block public access settings must be disabled first)
resource "aws_s3_bucket_public_access_block" "outputs" {
  bucket = aws_s3_bucket.outputs.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "outputs_public_read" {
  bucket = aws_s3_bucket.outputs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.outputs.arn}/*"
      },
      {
        # Public ListBucket makes missing keys return 404 instead of 403,
        # including through the CDN's pass-through origin, and lets the CDN's
        # storage browser list the bucket.
        Sid       = "PublicListBucket"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.outputs.arn
      }
    ]
  })

  # public_access_block must be applied before the public bucket policy
  depends_on = [aws_s3_bucket_public_access_block.outputs]
}

resource "aws_s3_bucket_cors_configuration" "outputs" {
  bucket = aws_s3_bucket.outputs.id

  # Restricted to the data CDN, as for mco-snodas: browsers use
  # data2.climate.umt.edu/snotel/, not the raw S3 endpoint.
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = [
      "https://d1s8jav5n0eyyf.cloudfront.net",
      "https://data2.climate.umt.edu",
    ]
    max_age_seconds = 3600
  }
}

# Plots are a permanent dated archive (~2,800 a night at ~80 KB, ~80 GB a
# year). After a year they move to Standard-IA, as mco-snodas's do: instantly
# readable, a small per-GB retrieval fee. The age is from upload, so
# backfilled plots move a year after upload.
resource "aws_s3_bucket_lifecycle_configuration" "outputs" {
  bucket = aws_s3_bucket.outputs.id

  rule {
    id     = "plots-to-standard-ia"
    status = "Enabled"

    filter {
      prefix = "plots/"
    }

    transition {
      days          = 365
      storage_class = "STANDARD_IA"
    }
  }
}
