# Shared pipeline setup for the entry points (mco-snotel.R, normals-annual.R,
# viz.R) and standalone scripts.
#
# Sets AWS environment defaults, defines pipeline constants, sources R/*.R,
# compiles the C++ distribution code, and registers fonts. Call once per R
# session before any stage function.

setup_pipeline <- function(compile = TRUE) {
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

  # The vendored distribution code (src/, from mco-snodas). ecdf_impl.h is
  # included by ecdf.cpp and zig.cpp.
  if (compile)
    for (f in c("ecdf", "zig", "zig_spline", "qnorm_grid"))
      Rcpp::sourceCpp(file.path("src", paste0(f, ".cpp")), env = globalenv())

  register_snodas_fonts()

  invisible(NULL)
}
