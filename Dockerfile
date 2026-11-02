# R 4.5.3 with CRAN pinned to the Posit Package Manager snapshot of
# 2026-04-23, so every R package below installs at that snapshot's version.
FROM rocker/r-ver:4.5.3@sha256:f5a72ffeea7ed592b2a5990f87101beef8ef3cae0e4ff7327088e80368f0aef9

# OpenBLAS picks its kernels by CPU, which moves the smoothed (zig_smooth) fits
# in the 7th-11th significant digit from one machine to another. One thread and
# one fixed kernel make the annual normals build the same on every host, and
# match the platform the normals package's golden fixtures are defined on
# (normals docs/API.md, section 7).
ENV OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 OPENBLAS_CORETYPE=Nehalem

# Nimbus Sans (registered as Helvetica for the plots by
# normals::register_plot_fonts()), AWS CLI v2 (S3 syncs), and the shared
# libraries the snapshot's binary R packages link that the base image lacks
# (libuv for fs, libwebpmux for ragg). curl and unzip only fetch the CLI.
ARG AWSCLI_VERSION=2.38.1
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip fonts-urw-base35=20200910-8 libuv1t64 libwebpmux3 && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# R packages from the image's dated snapshot. The pins that matter for
# matching mco-snodas are checked: RcppArmadillo (compiled into normals; the
# ZIG-smooth fit) and fastpng / colorfast (the fixed-palette PNGs). yaml is for
# the layout resolver (R/layout.R); remotes installs normals below.
RUN install2.r --error --skipinstalled --ncpus -1 \
      magrittr dplyr tidyr purrr tibble lubridate fs jsonlite yaml \
      arrow httr2 paws.storage \
      Rcpp RcppArmadillo remotes \
      ggplot2 patchwork gtable scales ragg png systemfonts colorfast fastpng && \
    Rscript -e " \
      pins <- c(RcppArmadillo = '15.2.6.1', fastpng = '0.1.8', colorfast = '1.0.1'); \
      got  <- vapply(names(pins), \(p) as.character(packageVersion(p)), ''); \
      if (!identical(unname(got), unname(pins))) stop('Unexpected package versions: ', paste(names(pins), got, collapse = ', ')) \
    " && \
    rm -rf /tmp/downloaded_packages

# The normals package (distributions, smoothing, percentiles and the shared plot
# helpers), at one commit. Its CRAN dependencies are already installed from the
# snapshot above; upgrade = "never" keeps them there.
ARG NORMALS_SHA=5633296a7aedd101d15059f29ab20ef7fdd0c144
RUN Rscript -e " \
      remotes::install_github('mt-climate-office/normals@${NORMALS_SHA}', \
                              dependencies = NA, upgrade = 'never', build_vignettes = FALSE); \
      got <- packageDescription('normals')\$RemoteSha; \
      if (!identical(got, '${NORMALS_SHA}')) stop('normals installed at ', got, ', not ${NORMALS_SHA}') \
    " && \
    rm -rf /tmp/downloaded_packages

WORKDIR /pipeline
COPY . /pipeline

ENTRYPOINT ["Rscript"]
CMD ["mco-snotel.R"]
