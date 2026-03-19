# MCO SNOTEL Pipeline

A daily data archive pipeline built on
[NRCS SNOTEL (Snow Telemetry)](https://www.nrcs.usda.gov/wps/portal/wcc/home/aboutUs/monitoringPrograms/automatedSnowMonitoring/).
Downloads observations from all SNOTEL stations, appends new records to a running Parquet
archive in S3, and tracks per-station fetch state for fully incremental updates — run daily
via an R orchestrator on ECS Fargate.

---

## Products

| Output | Format | Description |
|--------|--------|-------------|
| Raw station downloads | `.csv` (versioned) | One file per station containing its complete record exactly as returned by the NRCS API; overwritten each run, with S3 versioning preserving the full download history |
| Partitioned archive | `.parquet` (ZSTD, Arrow/Hive) | All stations combined into a Hive-partitioned dataset (`site_id={id}/part-0.parquet`), sorted by date within each partition for fast cloud-native queries by station and date range |
| Station metadata | `.parquet` (ZSTD) | NRCS station list with network, location, elevation, HUC, and period of record |
| Pipeline state | `.parquet` (ZSTD) | Per-station last date, record count, and last update timestamp |

---

## Pipeline

All stages run sequentially via `mco-snotel.R`:

```
mco-snotel.R
        │
        ├─ [Step 1]   Fetch station metadata from NRCS → stations/stations.parquet → S3
        │
        ├─ [Step 2]   Download complete record for every station in parallel (furrr
        │             multisession) → raw/{site_id}.parquet → S3 (versioned)
        │
        ├─ [Step 3]   Combine all raw files → write Hive-partitioned Arrow dataset
        │             (site_id={id}/part-0.parquet, sorted by date) → archive/ → S3
        │
        └─ [Step 4]   Summarise per-station last date + record count → cache/state.parquet → S3
```

---

## Raw Archive and Change History

Each run downloads the **complete record** for every station from the NRCS API and writes
it to `raw/{site_id}.parquet`, overwriting the previous file. Because S3 versioning is
enabled on the bucket, every overwrite creates a new object version — giving a dated record
of exactly what the NRCS API returned on each pipeline run. This makes it straightforward to
detect retroactive corrections in the source data or reconstruct the archive as it appeared
on any past date.

The `cache/state.parquet` file records `last_date`, `n_records`, and `updated_at` per
station as a lightweight operational summary, but it is not used to gate downloads — every
station is always fetched in full.

---

## Repository Structure

```
mco-snotel/
├── terraform/               AWS infrastructure (Terraform)
│   ├── main.tf              Provider + backend config
│   ├── variables.tf         Input variables
│   ├── locals.tf            Derived locals
│   ├── ecr.tf               ECR repository
│   ├── iam.tf               Task execution, task, and scheduler IAM roles
│   ├── ecs.tf               ECS cluster + Fargate task definition
│   ├── scheduler.tf         EventBridge daily trigger (10 AM Mountain)
│   ├── vpc.tf               VPC/subnet data sources
│   ├── s3.tf                Public S3 bucket + CORS
│   ├── cloudwatch.tf        Log group + failure alarm
│   ├── github-actions.tf    OIDC role for GitHub Actions ECR push
│   ├── outputs.tf           Key resource identifiers
│   └── terraform.tfvars.example
├── scripts/
│   ├── ecr-push.sh          Build and push Docker image to ECR
│   └── run_local.sh         Local run with AWS SSO auto-refresh
├── mco-snotel.R             Orchestrator — the single entry point (local and ECS)
├── Dockerfile
├── docker-compose.yml       Local development
├── .gitignore
└── README.md
```

### S3 Bucket Layout

```
s3://mco-snotel/
├── raw/                             # Complete per-station downloads (S3-versioned)
│   ├── 1001.csv                     # Full NRCS record for station 1001 (text/csv)
│   ├── 1002.csv
│   └── ...
├── archive/                         # Hive-partitioned Arrow dataset (rebuilt each run)
│   ├── site_id=1001/
│   │   └── part-0.parquet           # Station 1001, sorted by date (ZSTD)
│   ├── site_id=1002/
│   │   └── part-0.parquet
│   └── ...
├── stations/
│   └── stations.parquet             # NRCS station metadata (ZSTD)
└── cache/
    └── state.parquet                # Per-station last_date, n_records, updated_at (ZSTD)
```

The partitioned archive is designed for efficient cloud-native access via Arrow or DuckDB:

```r
# All data for one station
arrow::open_dataset("s3://mco-snotel/archive") |>
  dplyr::filter(site_id == 1001) |>
  dplyr::collect()

# SWE across all stations for a date range
arrow::open_dataset("s3://mco-snotel/archive") |>
  dplyr::filter(date >= as.Date("2024-01-01"), date <= as.Date("2024-03-31")) |>
  dplyr::select(site_id, date, snow_water_equivalent) |>
  dplyr::collect()
```

---

## Running Locally

**Prerequisites:**

- R 4.4+
- AWS CLI v2 configured with an `mco` profile: `aws sso login --profile mco`
- R packages: see `Dockerfile` for the full list; install with
  `pak::pkg_install(c("magrittr", "tidyverse", "snotelr", "arrow", "paws.storage", "fs", "furrr", "future"))`

**Set environment variables** (or accept the defaults shown below):

```bash
export S3_BUCKET="mco-snotel"        # default: mco-snotel
export WORK_DIR="s3"                 # local working directory; default: s3/
export CORES=4                       # parallel download workers; default: 4
export AWS_PROFILE="mco"             # default: mco
export AWS_DEFAULT_REGION="us-west-2"
```

**Run the full pipeline:**

```bash
Rscript mco-snotel.R
```

**Local data directory**

By default `WORK_DIR = "s3"`, which writes all outputs to `s3/` inside the repo. That
directory is gitignored. Point `WORK_DIR` anywhere outside the repo if you prefer:

```bash
export WORK_DIR=~/mco-snotel-data
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `S3_BUCKET` | `mco-snotel` | S3 bucket for all inputs and outputs |
| `WORK_DIR` | `s3` | Local working directory (ephemeral in ECS, persistent locally) |
| `KEEP_LOCAL` | `FALSE` | Keep all downloaded/produced files locally; set `true` in `docker-compose.yml` for a full local mirror of the S3 bucket |
| `CORES` | `4` | Number of parallel download workers |
| `AWS_PROFILE` | `mco` | AWS credentials profile |
| `AWS_DEFAULT_REGION` | `us-west-2` | AWS region |

---

## Cloud Architecture (AWS)

The pipeline runs daily on **AWS ECS Fargate** (10 AM Mountain Time), triggered by an
EventBridge Scheduler. All AWS infrastructure is managed by Terraform in `terraform/`.

### Resources

| Resource | Description |
|----------|-------------|
| ECR repository | `mco-snotel` — Docker image registry (5-image retention policy) |
| ECS cluster | Fargate, Container Insights enabled |
| ECS task | 1 vCPU / 4 GB RAM / 21 GiB ephemeral storage |
| EventBridge Scheduler | Daily at 10 AM America/Denver, 1 retry |
| S3 bucket | `mco-snotel` — public read, CORS enabled, versioning enabled |
| CloudWatch log group | `/ecs/mco-snotel`, 90-day retention |
| IAM roles | Task execution (ECR pull + CW logs), task (S3 read/write), scheduler (ECS RunTask) |

### Deploy infrastructure

```bash
cd terraform

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan
terraform apply
```

`terraform.tfvars` is gitignored — never commit it.

### Build and push the Docker image

```bash
# Authenticate, build for linux/amd64, and push to ECR
./scripts/ecr-push.sh          # tags as :latest
./scripts/ecr-push.sh v1.2.3   # also tags the version, plus re-tags :latest
```

The script resolves your AWS account ID automatically via `aws sts get-caller-identity`.

### GitHub Actions

Pushing to `main` automatically builds and pushes the Docker image to ECR via the
`.github/workflows/docker-publish.yml` workflow. Authentication uses OIDC — no stored AWS
credentials required. The IAM role (`mco-snotel-ecr-push`) is managed by Terraform in
`terraform/github-actions.tf`.

### Run locally with Docker Compose

```bash
./scripts/run_local.sh
```

This refreshes AWS SSO credentials, injects short-lived STS credentials into the container
environment, and re-runs automatically if credentials expire mid-pipeline.

Or invoke Docker Compose directly:

```bash
docker compose up
```

### Run manually on ECS

```bash
# Trigger a one-off run (uses the current task definition)
aws ecs run-task \
  --cluster mco-snotel \
  --task-definition mco-snotel \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],assignPublicIp=ENABLED}" \
  --profile mco
```

**Container entry point:** `Rscript mco-snotel.R`

**Build and run locally with Docker:**

```bash
# Build
docker build -t mco-snotel .

# Run (uses local AWS credentials via ~/.aws)
docker run --rm \
  -v ~/.aws:/root/.aws:ro \
  -e AWS_PROFILE="mco" \
  -e AWS_DEFAULT_REGION="us-west-2" \
  mco-snotel
```

---

## Data Source

Observations are downloaded via the [`snotelr`](https://github.com/bluegreen-labs/snotelr)
package, which wraps the
[NRCS Water and Climate Center Report Generator](https://wcc.sc.egov.usda.gov/reportGenerator/).

- **Network:** NRCS SNOTEL (Snow Telemetry) and SCAN (Soil Climate Analysis Network)
- **Variables:** Snow water equivalent, precipitation (cumulative and incremental), air
  temperature (max, min, mean), and additional sensor readings as available per station
- **Spatial coverage:** Western United States and Alaska
- **Temporal coverage:** 1980-01-01 to present (daily; period of record varies by station)
- **Station count:** ~900 active and historical stations
- **Landing page:** <https://www.nrcs.usda.gov/wps/portal/wcc/home/aboutUs/monitoringPrograms/automatedSnowMonitoring/>

> National Water and Climate Center (NWCC), Natural Resources Conservation Service (NRCS),
> U.S. Department of Agriculture. *SNOTEL (SNOwpack TELemetry) Network*.
> <https://www.nrcs.usda.gov/wps/portal/wcc/home/>
