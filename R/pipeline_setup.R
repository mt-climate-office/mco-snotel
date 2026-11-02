# Shared pipeline setup for the entry points (mco-snotel.R, normals-annual.R,
# viz.R) and standalone scripts.
#
# Sets AWS environment defaults, sources R/*.R, defines pipeline constants,
# and registers fonts. The distribution code is the normals package (see the
# Dockerfile). Call once per R session before any stage function.

setup_pipeline <- function() {
  Sys.setenv(
    AWS_PROFILE        = Sys.getenv("AWS_PROFILE",        unset = "mco"),
    AWS_DEFAULT_REGION = Sys.getenv("AWS_DEFAULT_REGION", unset = "us-west-2")
  )

  # Source R/*.R, except this file.
  r_files <- fs::dir_ls("R", glob = "*.R")
  r_files <- r_files[basename(r_files) != "pipeline_setup.R"]
  purrr::walk(r_files, source)

  # Pipeline constants, assigned globally so the stage functions and R/*.R
  # helpers can see them. S3 keys come from the layout resolver (R/layout.R,
  # config/layout.yml); the bucket is LAYOUT_BUCKET or S3_BUCKET, else the
  # layout's. Local copies sit at the same keys under OUTPUT_DIR.
  S3_BUCKET  <<- layout_bucket()
  OUTPUT_DIR <<- Sys.getenv("WORK_DIR",  unset = "s3")
  KEEP_LOCAL <<- isTRUE(as.logical(Sys.getenv("KEEP_LOCAL", unset = "TRUE")))
  CORES      <<- max(1L, as.integer(Sys.getenv("CORES", unset = "1")))

  fs::dir_create(OUTPUT_DIR, recurse = TRUE)

  normals::register_plot_fonts()

  invisible(NULL)
}
