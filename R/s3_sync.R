# Vendored from mco-snodas@62fe19a: s3_list_prefix() and aws_s3() from
# R/pipeline_sync.R, s3_exists() from R/normals_annual.R. Do not edit here:
# change them upstream, then copy them back (see README, "Vendored code").

#' List all S3 objects under a prefix, handling pagination.
s3_list_prefix <- function(s3, bucket, prefix) {
  objs  <- list()
  token <- NULL
  repeat {
    args <- list(Bucket = bucket, Prefix = prefix, MaxKeys = 1000L)
    if (!is.null(token)) args$ContinuationToken <- token
    resp <- do.call(s3$list_objects_v2, args)
    objs <- c(objs, resp$Contents)
    if (!isTRUE(resp$IsTruncated)) break
    token <- resp$NextContinuationToken
  }
  objs
}

#' Run an `aws s3` command (e.g. multipart cp, parallel sync).
#'
#' In ECS the CLI must use the task role. setup_pipeline() sets
#' AWS_PROFILE = "mco", which paws tolerates but the CLI rejects when that
#' profile is absent, so it is unset there. An empty AWS_PROFILE (local
#' backfills with exported credentials) is unset too, since the CLI rejects it.
aws_s3 <- function(args) {
  in_ecs <- nzchar(Sys.getenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"))
  unset_profile <- in_ecs || !nzchar(Sys.getenv("AWS_PROFILE"))
  status <- system2("env", c(if (unset_profile) c("-u", "AWS_PROFILE"),
                             "AWS_RETRY_MODE=standard", "AWS_MAX_ATTEMPTS=10",
                             "aws", "s3", args, "--only-show-errors", "--cli-read-timeout", "120"))
  if (status != 0) stop("aws s3 ", args[1], " failed: ", paste(args, collapse = " "))
  invisible(status)
}

s3_exists <- function(key) {
  tryCatch({ paws.storage::s3()$head_object(Bucket = S3_BUCKET, Key = key); TRUE },
           error = \(e) FALSE)
}
