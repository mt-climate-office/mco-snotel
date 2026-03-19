FROM rocker/r-ver:4.5

# Install AWS CLI v2 and system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install R packages via pak
RUN Rscript -e " \
  install.packages('pak', repos = 'https://r-lib.github.io/p/pak/stable/'); \
  pak::pkg_install(c( \
    'magrittr', \
    'tidyverse', \
    'lubridate', \
    'snotelr', \
    'arrow', \
    'paws.storage', \
    'fs', \
    'furrr', \
    'future' \
  )) \
"

WORKDIR /pipeline
COPY . /pipeline

ENTRYPOINT ["Rscript", "mco-snotel.R"]
