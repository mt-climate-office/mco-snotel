# Copied from mco-snodas@62fe19a R/s3.R. The normals package does no storage,
# so S3 access stays in each pipeline.

# Download an S3 object to dest. Returns TRUE on success and FALSE on any
# error, so callers can treat a missing key as absent.
s3_get_file <- function(
    bucket,
    key,
    dest,
    s3 = paws.storage::s3()
) {
  fs::dir_create(dirname(dest), recurse = TRUE)
  tryCatch({
    resp <- s3$get_object(Bucket = bucket, Key = key)
    writeBin(resp$Body, dest)
    TRUE
  }, error = function(e) {
    FALSE
  })
}

# Upload a local file to S3.
s3_put_file <- function(
    path,
    bucket,
    key = basename(path),
    content_type = NULL,
    s3 = paws.storage::s3()
) {
  raw <- readBin(path, what = "raw", n = file.info(path)$size)
  args <- list(Bucket = bucket, Key = key, Body = raw)
  if (!is.null(content_type)) args$ContentType <- content_type
  invisible(do.call(s3$put_object, args))
}
