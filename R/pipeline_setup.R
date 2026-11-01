# Shared pipeline setup for the entry points (mco-snotel.R, normals-annual.R,
# viz.R) and standalone scripts.
#
# Sets AWS environment defaults, defines pipeline constants, sources R/*.R,
# and registers fonts. The distribution code is the normals package (see the
# Dockerfile). Call once per R session before any stage function.

setup_pipeline <- function() {
  Sys.setenv(
    AWS_PROFILE        = Sys.getenv("AWS_PROFILE",        unset = "mco"),
    AWS_DEFAULT_REGION = Sys.getenv("AWS_DEFAULT_REGION", unset = "us-west-2")
  )

  # Pipeline constants, assigned globally so the stage functions and R/*.R
  # helpers can see them.
  S3_KEY_STATIONS   <<- "stations/stations.parquet"
  S3_KEY_ARCHIVE    <<- "archive/snotel.parquet"
  S3_KEY_STATE      <<- "cache/state.parquet"
  S3_PREFIX_NORMALS <<- "normals"
  S3_PREFIX_PLOTS   <<- "plots"
  S3_PREFIX_LATEST  <<- "latest"

  S3_BUCKET  <<- Sys.getenv("S3_BUCKET", unset = "mco-snotel")
  OUTPUT_DIR <<- Sys.getenv("WORK_DIR",  unset = "s3")
  KEEP_LOCAL <<- isTRUE(as.logical(Sys.getenv("KEEP_LOCAL", unset = "TRUE")))
  CORES      <<- max(1L, as.integer(Sys.getenv("CORES", unset = "1")))

  fs::dir_create(OUTPUT_DIR, recurse = TRUE)

  # Source R/*.R, except this file.
  r_files <- fs::dir_ls("R", glob = "*.R")
  r_files <- r_files[basename(r_files) != "pipeline_setup.R"]
  purrr::walk(r_files, source)

  normals::register_plot_fonts()

  invisible(NULL)
}
