#!/usr/bin/env Rscript
# Check how well the shared plot palette (normals::plot_palette(), shared
# with mco-snodas) fits the station plots.
#
# Renders sample station plots in full colour, quantizes them to the shared
# palette exactly as normals::plot_save_png() does, and reports the colour error. For
# comparison, it also fits a 256-colour palette to the station plots alone
# (pngquant, as mco-snodas's scripts/build-plot-palette.R does) and reports
# that palette's error. The shared palette is never written here: it is the
# normals package's, so legends match across the two products. If it is
# clearly worse, rebuild it there from both products' plots.
#
# Usage: Rscript scripts/check-plot-palette.R [DATE]
#   Needs the date's water year normals and percentiles in WORK_DIR or S3, and
#   pngquant on the PATH.

suppressPackageStartupMessages({
  library(magrittr); library(ggplot2); library(patchwork); library(lubridate)
})
source("R/pipeline_setup.R")
setup_pipeline()
if (!nzchar(Sys.which("pngquant"))) stop("pngquant is needed for the comparison palette")

# Stations from valley to alpine, Montana to Alaska and the Southwest.
SAMPLE_STATIONS <- c("901:MT:SNTL", "918:MT:SNTL", "787:MT:SNTL", "1322:MT:SNTL",
                     "1315:AK:SNTL", "1215:UT:SNTL", "1000:OR:SNTL", "1001:AK:SNTL")
args <- commandArgs(TRUE)
date <- if (length(args)) lubridate::as_date(args[1]) else latest_swe_date(Sys.Date())

# Full-colour PNGs: the sample must not already be on the palette.
full_colour <- tempfile("palette-sample-")
snotel_save_png <- function(p, file, width = 8, height = 16 / 3, dpi = 187.5) {
  file <- file.path(full_colour, basename(dirname(dirname(dirname(file)))), basename(file))
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  ggplot2::ggsave(file, p, device = ragg::agg_png, width = width, height = height, dpi = dpi, bg = "white")
}
meta <- stations_read()
stage_viz(date, stations = intersect(SAMPLE_STATIONS, meta$triplet), cores = 1L, upload = FALSE)

files <- list.files(full_colour, "\\.png$", full.names = TRUE, recursive = TRUE)
if (!length(files)) stop("No sample plots were drawn for ", date)
rgb_of <- \(f) { x <- png::readPNG(f)[, , 1:3]; round(cbind(c(x[, , 1]), c(x[, , 2]), c(x[, , 3])) * 255) }

# Mean and max RGB distance (0-255 scale) from each pixel to its palette colour.
quant_error <- function(px, pal) {
  key <- px[, 1] * 65536 + px[, 2] * 256 + px[, 3]
  u   <- unique(key)
  uc  <- cbind(u %/% 65536, (u %/% 256) %% 256, u %% 256)
  d   <- outer(uc[, 1], pal[, 1], "-")^2 + outer(uc[, 2], pal[, 2], "-")^2 + outer(uc[, 3], pal[, 3], "-")^2
  e   <- sqrt(d[cbind(seq_len(nrow(uc)), max.col(-d, ties.method = "first"))])
  e   <- e[match(key, u)]
  c(mean = mean(e), max = max(e))
}

px <- do.call(rbind, lapply(files, rgb_of))

# A palette fitted to these plots alone: the sample stacked into one image,
# quantized by pngquant.
imgs <- lapply(files, \(f) png::readPNG(f)[, , 1:3])
h <- dim(imgs[[1]])[1]
stack <- array(1, c(h * length(imgs), dim(imgs[[1]])[2], 3))
for (i in seq_along(imgs)) stack[(i - 1) * h + seq_len(h), , ] <- imgs[[i]]
montage <- tempfile(fileext = ".png"); quant <- tempfile(fileext = ".png")
png::writePNG(stack, montage)
rm(imgs, stack)
status <- system2("pngquant", c("256", "--nofs", "--speed", "1", "--force", "--output", shQuote(quant), shQuote(montage)))
if (status != 0) stop("pngquant failed (exit ", status, ")")
own <- unique(rgb_of(quant))

shared <- quant_error(px, normals::plot_palette()$rgb)
fitted <- quant_error(px, own)
message(sprintf("%d plots from %s (%s)", length(files), format(date), paste(unique(basename(dirname(files))), collapse = ", ")))
message(sprintf("  shared palette (mco-snodas):  mean %.3f, max %.1f (of 255)", shared["mean"], shared["max"]))
message(sprintf("  fitted to these plots alone:  mean %.3f, max %.1f (of 255)", fitted["mean"], fitted["max"]))
unlink(c(full_colour, montage, quant), recursive = TRUE)
