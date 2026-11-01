# S3 path inventory: mco-snotel and mco-snodas (layout_version 0)

Every place either repository builds an S3 key or prefix, as of:
- mco-snotel `main` f39fe56, plus branch `outlook` (bb8d06a, marked **[outlook]**);
- mco-snodas `main` 9b45d74.

It is the input for steps 2B (mco-snodas) and 2C (mco-snotel), which replace each site with a
call to the resolver (`R/layout.R`). The artifact column is the ID in `config/layout.yml`
(mco-snotel) or `config/layout-snodas.yml` (mco-snodas, moving there in 2B as
`config/layout.yml`). `scripts/test_layout.R` checks that each artifact resolves to exactly
the key the code builds, using the code's own expressions and real keys listed from both
buckets on 2026-11-01.

**Conventions**
- Op: **R** read (GET or HEAD), **W** write (PUT, copy or sync up), **D** delete, **L** list.
  `–` is a constant or helper; `doc` is documentation or a value written inside an object.
- `{date}` is `YYYY-MM-DD` and `{compact_date}` is `YYYYMMDD`. `{wy}` is a water year.
  `{role}` is a role (`30yr`, `snodas`, `por`), which is the period folder in v0.
- Flavors are `{flavor}` ∈ `ecdf`, `zig`, `zig_smooth` in v0. The resolver also takes
  `empirical`, `fitted` and `smoothed`.
- `{subject}` is a station (`901_MT_SNTL`, the triplet with `_` for `:`) or a HUC (`01010002`).
- Local paths are `{OUTPUT_DIR}/{key}` (`WORK_DIR`, default `s3`) unless noted. The resolver's
  keys therefore serve as local paths too.

## Summary

Sites are table rows below: code, scripts, infrastructure and docs, including constants.

| | Sites | Artifacts |
|---|---|---|
| mco-snotel (main) | 86 | 18 |
| mco-snotel [outlook] | 16 more | 19 (adds `outlook`; `latest_copy` gains `artifact = "outlook"`) |
| mco-snodas | 172 | 35 (33 written by code, plus 2 legacy read-only: `animations/sy2026/`) |
| Shared `scripts/parity/seed.sh` | 21 (both projects) | in both counts |

**Real keys.** All 923,752 keys in `s3://mco-snotel` belong to exactly one v0 artifact
(`scripts/test_layout.R --snotel-listing`). For `s3://mco-snodas`, see that section.

---

## mco-snotel

### Constants and helpers

| file:line | template as written | artifact | op |
|---|---|---|---|
| R/pipeline_setup.R:16 | `S3_KEY_STATIONS <<- "stations/stations.parquet"` | subjects | – |
| R/pipeline_setup.R:17 | `S3_KEY_ARCHIVE <<- "archive/snotel.parquet"` | raw | – |
| R/pipeline_setup.R:18 | `S3_KEY_STATE <<- "cache/state.parquet"` | cache (`file = "state.parquet"`) | – |
| R/pipeline_setup.R:19 | `S3_PREFIX_NORMALS <<- "normals"` | (prefix of normals_*, reference, percentiles, outlook) | – |
| R/pipeline_setup.R:20 | `S3_PREFIX_PLOTS <<- "plots"` | (prefix of plot, plot_index) | – |
| R/pipeline_setup.R:21 | `S3_PREFIX_LATEST <<- "latest"` | (prefix of latest_*) | – |
| R/pipeline_setup.R:23 | `S3_BUCKET <<- Sys.getenv("S3_BUCKET", unset = "mco-snotel")` | bucket (`layout_bucket()`) | – |
| R/pipeline_setup.R:24 | `OUTPUT_DIR <<- Sys.getenv("WORK_DIR", unset = "s3")` | local mirror root | – |
| R/stages.R:20 | `normals_prefix(period, wy)`: `file.path(S3_PREFIX_NORMALS, period, paste0("wy", wy))` → `normals/{role}/wy{wy}` | `layout_prefix("normals_table", role, wy)` | – |
| R/stages.R:21 | `reference_key(wy)`: `normals/reference/wy{wy}.parquet` | reference | – |
| R/stages.R:22 | `observed_key(period, wy)`: `normals/{role}/observed/wy{wy}.parquet` | percentiles | – |
| outlook:R/stages.R:23-24 | **[outlook]** `outlook_key(period, date)`: `normals/{role}/outlook/wy{wy(date)}/{date}.parquet` | outlook | – |
| R/stages.R:34-41 | `s3_sync_dir(local_dir, prefix)`: `paste0("s3://", S3_BUCKET, "/", prefix)` | (any prefix) | W |
| R/stages.R:51-56 | `s3_local(key)`: local `file.path(OUTPUT_DIR, key)`, GET `key` | (any) | R |
| R/s3.R:6-20 | `s3_get_file(bucket, key, dest)` | (any) | R |
| R/s3.R:23-34 | `s3_put_file(path, bucket, key)` | (any) | W |
| R/s3_sync.R:6-18 | `s3_list_prefix(s3, bucket, prefix)` (unused in mco-snotel) | – | L |
| R/s3_sync.R:36-39 | `s3_exists(key)`: HEAD on `S3_BUCKET` | (any) | R |
| R/archive.R:11 | `archive_local()`: `file.path(OUTPUT_DIR, S3_KEY_ARCHIVE)` | raw (local) | – |

### Stages

| file:line | template as written | artifact | op |
|---|---|---|---|
| R/stages.R:59-60 | `s3_local(S3_KEY_STATIONS)` | subjects | R |
| R/stages.R:70-71 | `file.path(OUTPUT_DIR, S3_KEY_STATIONS)`; `s3_put_file(…, S3_KEY_STATIONS)` | subjects | W |
| R/archive.R:28-31 | `s3_get_file(S3_BUCKET, S3_KEY_ARCHIVE, path)` | raw | R |
| R/archive.R:33-35 | `s3_put_file(path, S3_BUCKET, S3_KEY_ARCHIVE)` | raw | W |
| R/archive.R:67 | `"s3://", S3_BUCKET, "/", S3_KEY_ARCHIVE` (message) | raw | doc |
| R/archive.R:41, :73 | local `{OUTPUT_DIR}/work/awdb-full`, `…/awdb-recent` | (local only) | – |
| R/archive.R:105-108 | `file.path(OUTPUT_DIR, S3_KEY_STATE)`; `s3_put_file(…, S3_KEY_STATE)` | cache `state.parquet` | W |
| R/stages.R:105-106 | `reference_key(wy)` | reference | W |
| R/stages.R:112-113 | local `{OUTPUT_DIR}/normals/{role}/wy{wy}` emptied | (local) | – |
| R/stages.R:115 | `file.path(out, "normals.parquet")` | normals_table | W (:147) |
| R/stages.R:116 | `file.path(out, "zig_smooth_coef.parquet")` | normals_coef | W (:147) |
| R/stages.R:117 | `file.path(out, "zig_smooth_diagnostics.parquet")` | normals_diagnostics | W (:147) |
| R/stages.R:120 | `file.path(out, "by_station", paste0(gsub(":", "_", trip), ".parquet"))` | normals_by_subject | W (:147) |
| R/stages.R:124 | `file.path(out, "zig_smooth_basis.csv")` | normals_basis | W (:147) |
| R/stages.R:132 | `file.path(out, "zig_smooth_model.json")` | normals_model | W (:147) |
| R/stages.R:136 | `reference_record = reference_key(wy)` inside provenance.json | reference | doc |
| R/stages.R:145 | `file.path(out, "provenance.json")` | provenance | W (:147) |
| R/stages.R:147 | `s3_sync_dir(out, normals_prefix(period, wy))` | the normals folder | W |
| R/stages.R:165-167 | `s3_local(reference_key(wy))` | reference | R |
| R/stages.R:176 | `file.path(normals_prefix(period, wy), "normals.parquet")` | normals_table | R |
| R/stages.R:182-184 | `observed_key(period, wy)` | percentiles | W |
| R/stages.R:208 | `out_root <- file.path(OUTPUT_DIR, S3_PREFIX_PLOTS, format(date))` | `layout_prefix("plot", date)` (local) | – |
| R/stages.R:213 | `…/normals.parquet` | normals_table | R |
| R/stages.R:214 | `observed_key(period, wy)` | percentiles | R |
| R/stages.R:220 | `file.path(normals_prefix(period, wy), "provenance.json")` | provenance | R |
| R/stages.R:248 | `file.path(out_root, period, fl, "swe", "usdm", paste0(st$station, ".png"))` | plot | W (:290) |
| R/stages.R:273 | `index_key <- file.path(S3_PREFIX_PLOTS, format(date), "index.json")` | plot_index | – |
| R/stages.R:274 | `s3_local(index_key)` (merged with this run's periods) | plot_index | R |
| R/stages.R:283 | `path = "{period}/{flavor}/{type}/{style}/{station}.png"` inside index.json | plot | doc |
| R/stages.R:290 | `s3_sync_dir(out_root, file.path(S3_PREFIX_PLOTS, format(date)), exclude = "index.json")` | plot | W |
| R/stages.R:291 | `s3_put_file(…, index_key)`, written last | plot_index | W |
| R/stages.R:309 | `S3_KEY_STATIONS` → `file.path(S3_PREFIX_LATEST, "stations.parquet")` | subjects → latest_subjects | R, W |
| R/stages.R:310-311 | `observed_key(p, wy)` → `file.path(S3_PREFIX_LATEST, paste0("observed_", p, ".parquet"))` | percentiles → latest_copy (`artifact = "percentiles"`) | R, W |
| outlook:R/stages.R:402-403 | **[outlook]** `outlook_key(p, date)` → `latest/outlook_{p}.parquet` | outlook → latest_copy (`artifact = "outlook"`) | R, W |
| R/stages.R:315, :318 | `s3_exists(src)`; else `delete_object(Key = dest)` | latest_subjects, latest_copy | R, D |
| R/stages.R:321 | `copy_object(CopySource = paste0(S3_BUCKET, "/", src), Key = dest)` | latest_* | W |
| R/stages.R:325-326 | `s3_exists(file.path(normals_prefix(p, wy), "normals.parquet"))`; the folder goes into the manifest | normals_table | R, doc |
| R/stages.R:327 | `plots_key <- file.path(S3_PREFIX_PLOTS, format(date))`, in the manifest (no trailing `/`) | `layout_prefix("plot", date, slash = FALSE)` | doc |
| R/stages.R:333 | `archive = S3_KEY_ARCHIVE` in the manifest | raw | doc |
| R/stages.R:334 | `files = files` (the latest keys) in the manifest | latest_* | doc |
| R/stages.R:336 | `s3_exists(file.path(plots_key, "index.json"))` | plot_index | R |
| outlook:R/stages.R:414-415 | **[outlook]** `outlook` map in the manifest: `outlook_key(p, date)` | outlook | doc |
| R/stages.R:339 | `Key = file.path(S3_PREFIX_LATEST, "manifest.json")` | latest_manifest | W |
| R/stages.R:348 | `archive_local()` (local copy) | raw | R |
| outlook:R/stages.R:230 | **[outlook]** `s3_local(reference_key(wy))` | reference | R |
| outlook:R/stages.R:237 | **[outlook]** `…/normals.parquet` | normals_table | R |
| outlook:R/stages.R:243-244 | **[outlook]** `outlook_key(period, date)` | outlook | W |
| outlook:R/stages.R:274-281 | **[outlook]** as main :213-220 | normals_table, percentiles, provenance | R |
| outlook:R/stages.R:316 | **[outlook]** as main :248 | plot | W |
| outlook:R/stages.R:341-359 | **[outlook]** as main :273-291 | plot_index, plot | R, W |
| outlook:R/stages.R:371 | **[outlook]** `s3_local(outlook_key(period, date))` | outlook | R |
| outlook:R/stages.R:374-375 | **[outlook]** `reference_key(wy)`, `…/normals.parquet` | reference, normals_table | R |

### Scripts, infrastructure, docs

| file:line | template as written | artifact | op |
|---|---|---|---|
| scripts/backfill-figures.sh:23 | `BUCKET="mco-snotel"` | bucket | – |
| scripts/backfill-figures.sh:39 | `"s3://$BUCKET/plots/$1/index.json"` | plot_index | R |
| scripts/publish-bucket-readmes.sh:7 | `s3-docs/**/README.md` → `"s3://mco-snotel/"` + the same relative path | readme (`dir`) | W |
| scripts/parity/seed.sh | shared with mco-snodas; see [seed.sh](#shared-scriptsparityseedsh) | | |
| scripts/parity/diff.R:106-122 | any `s3://bucket/prefix` given as an argument | – | L, R |
| outlook:scripts/outlook-hindcast.R:20-21 | **[outlook]** "local copy of archive/snotel.parquet", "…stations/stations.parquet" (arguments are local files) | raw, subjects | doc |
| terraform/variables.tf:68 | `s3_bucket_name` default `"mco-snotel"` | bucket | – |
| terraform/variables.tf:124 | `shadow_s3_bucket_name` default `"mco-snotel-test"` | bucket (shadow) | – |
| terraform/ecs.tf:49 | `{ name = "S3_BUCKET", value = var.s3_bucket_name }` | `LAYOUT_BUCKET` / `S3_BUCKET` | – |
| terraform/shadow.tf:222 | `{ name = "S3_BUCKET", value = aws_s3_bucket.shadow.bucket }` | `LAYOUT_BUCKET` / `S3_BUCKET` | – |
| terraform/iam.tf:56-57, s3.tf:35, shadow.tf:93-144 | bucket ARNs and `arn/*`: whole bucket, no key prefixes | – | – |
| docker-compose.yml:9-10 | `S3_BUCKET: mco-snotel`, `WORK_DIR: /pipeline/s3` | bucket | – |
| CONSUMERS.md:20 | `latest/manifest.json` | latest_manifest | doc |
| CONSUMERS.md:23 | `latest/observed_{period}.parquet` | latest_copy | doc |
| outlook:CONSUMERS.md:25 | **[outlook]** `latest/outlook_{period}.parquet` | latest_copy | doc |
| CONSUMERS.md:37 | `stations/stations.parquet` | subjects | doc |
| CONSUMERS.md:38 | `archive/snotel.parquet` | raw | doc |
| CONSUMERS.md:39 | `normals/{period}/wy{YYYY}/normals.parquet` | normals_table | doc |
| CONSUMERS.md:40 | `normals/{period}/wy{YYYY}/by_station/{station}.parquet` | normals_by_subject | doc |
| CONSUMERS.md:41 | `normals/{period}/observed/wy{YYYY}.parquet` | percentiles | doc |
| CONSUMERS.md:42 | `normals/{period}/wy{YYYY}/provenance.json` | provenance | doc |
| CONSUMERS.md:43 | `normals/reference/wy{YYYY}.parquet` | reference | doc |
| outlook:CONSUMERS.md:44 | **[outlook]** `normals/{period}/outlook/wy{YYYY}/{d}.parquet` | outlook | doc |
| CONSUMERS.md:44 | `plots/{d}/{period}/{flavor}/swe/usdm/{station}.png` | plot | doc |
| CONSUMERS.md:76 | `plots/{d}/index.json` | plot_index | doc |
| s3-docs/README.md:14-20 | `latest/`, `stations/`, `archive/`, `normals/<period>/wy<YYYY>/`, `normals/<period>/observed/`, `plots/<YYYY-MM-DD>/`, `cache/` | (folders) | doc |
| s3-docs/latest/README.md:3-24 | `manifest.json`, `stations.parquet`, `observed_<period>.parquet` (**[outlook]** adds `outlook_<period>.parquet` and the manifest's `outlook` map) | latest_* | doc |
| s3-docs/normals/README.md:28-35 | the normals folder files, `observed/`, `reference/` (**[outlook]** adds `<period>/outlook/wy<YYYY>/<YYYY-MM-DD>.parquet`) | normals_*, percentiles, reference, outlook | doc |
| s3-docs/plots/README.md:10, :22 | `<YYYY-MM-DD>/<period>/<flavor>/swe/usdm/<station>.png`, `<YYYY-MM-DD>/index.json` | plot, plot_index | doc |
| s3-docs/{archive,cache,stations}/README.md | `snotel.parquet`, `state.parquet`, `stations.parquet` | raw, cache, subjects | doc |
| README.md:17-35, :61 | stage → prefix table; `normals/reference/wy{YYYY}.parquet` | (several) | doc |

---

## mco-snodas

Abbreviations: `{ZG}` = `normals/gridded`, `{ZW}` = `normals/zonal/wbd`,
`{BZ}` = `normals/zonal/wbd/by_zone`, `{NB}` = `normals/build`.

### Constants and helpers

| file:line | template as written | artifact | op |
|---|---|---|---|
| R/pipeline_setup.R:20 | `S3_PREFIX_RAW = "raw"` | (raw_tar) | – |
| R/pipeline_setup.R:21 | `S3_PREFIX_COGS = "cogs"` | (raw_cog) | – |
| R/pipeline_setup.R:22 | `S3_PREFIX_NORMALS_GRIDDED = "normals/gridded"` | (normals_grid*, percentile_grid, provenance_grid) | – |
| R/pipeline_setup.R:23 | `S3_PREFIX_NORMALS_ZONAL_WBD = "normals/zonal/wbd"` | (normals_table_day, provenance_day, means_day, percentiles) | – |
| R/pipeline_setup.R:24 | `S3_PREFIX_NORMALS_BY_ZONE = "normals/zonal/wbd/by_zone"` | (normals_by_subject) | – |
| R/pipeline_setup.R:25 | `S3_PREFIX_NORMALS_BUILD = "normals/build"` (must equal TF `var.normals_build_prefix`) | (normals_build, normals_build_current) | – |
| R/pipeline_setup.R:26 | `S3_PREFIX_LATEST = "latest"` | (latest_*) | – |
| R/pipeline_setup.R:27 | `S3_KEY_MANIFEST = "manifest.parquet"` | raw_manifest | – |
| R/pipeline_setup.R:28 | `S3_KEY_DATES_STATE = "cache/dates_state.parquet"` | cache `dates_state.parquet` | – |
| R/pipeline_setup.R:29 | `S3_KEY_NORMALS_STATE = "cache/normals_state.parquet"` | cache `normals_state.parquet` | – |
| R/pipeline_setup.R:31 | `S3_BUCKET = Sys.getenv("S3_BUCKET", unset = "mco-snodas")` | bucket | – |
| R/pipeline_setup.R:32 | `OUTPUT_DIR = Sys.getenv("WORK_DIR", unset = "s3")` | local mirror root | – |
| R/animate.R:14 | `S3_PREFIX_ANIMATIONS <- "animations"` | (animation, animation_index) | – |
| R/s3.R:3-17, :20-31 | `s3_get_file`, `s3_put_file(path, bucket, key = basename(path))` | (any) | R, W |
| R/pipeline_sync.R:6-18 | `s3_list_prefix(s3, bucket, prefix)`: prefix as given | (any) | L |
| R/pipeline_sync.R:254-278 | `s3_sync_down(prefix, local_dir, include)`: lists without adding `/`; local `local_dir/sub("^prefix/?", "", key)` | (any) | L, R |
| R/pipeline_sync.R:300-328 | `s3_sync_up(local_dir, prefix)`: `key <- paste0(prefix, "/", rel)` (:315); `delete = TRUE` branch unused | (any) | W, (D) |
| R/snodas_raw.R:14 | `paste0("SNODAS_", year, month, day, ".tar")` | raw_tar (file name) | – |
| R/snodas_raw.R:180-182 | `snodas_cog_filename`: `snodas_{var}_{compact_date}.tif` | raw_cog (file name) | – |
| R/snodas_raw.R:185-187 | `snodas_cog_key`: `file.path(S3_PREFIX_COGS, format(date), …)` → `cogs/{date}/snodas_{var}_{compact_date}.tif` | raw_cog | – |
| R/snodas_raw.R:190-192 | `snodas_cog_local`: `{OUTPUT_DIR}/cogs/…` | raw_cog (local) | – |
| R/normals_annual.R:34 | `normals_build_prefix(wy)`: `normals/build/wy{wy}` | normals_build | – |
| R/normals_annual.R:42-45 | `s3_exists(key)`: HEAD | (any) | R |
| R/normals_annual.R:47-49 | `s3_list_keys(prefix)`: lists `paste0(prefix, "/")` | (any) | L |
| R/normals_annual.R:51-57 | `s3_put_json(x, key)` | (any) | W |
| R/normals_annual.R:59-67 | `s3_delete_prefix(prefix)`: lists `prefix/`, deletes in batches of 1000 | (any) | L, D |
| R/normals_annual.R:112-122 | `s3_sync_up_large(local_dir, prefix)`: `key <- file.path(prefix, rel)`; `aws s3 cp` to `s3://{bucket}/{key}` above 1e9 bytes | (any) | W |
| R/stages.R:487-488 | `viz_get_file(key, local)`: GET, or (VIZ_OFFLINE) the local file | (any) | R |

### Daily stages 1-2: state, raw, COGs

| file:line | template as written | artifact | op |
|---|---|---|---|
| R/pipeline_sync.R:34-40 | `cache/dates_state.parquet` | cache `dates_state.parquet` | R |
| R/pipeline_sync.R:62-65 | list `raw/`; basename `^SNODAS_(\d{8})\.tar$` | raw_tar | L |
| R/pipeline_sync.R:105-109 | list the whole `cogs/` tree; basename `^[Ss][Nn][Oo][Dd][Aa][Ss]_[Ss][Ww][Ee]_(\d{8})\.tif$` | raw_cog | L |
| R/pipeline_sync.R:132 | `cache/normals_state.parquet` | cache `normals_state.parquet` | R |
| R/pipeline_sync.R:144, :151 | `cache/dates_state.parquet`, `cache/normals_state.parquet` | cache | W |
| R/stages.R:21-22 | `manifest.parquet` → `{OUTPUT_DIR}/manifest.parquet` | raw_manifest | R |
| R/stages.R:26-30 | list `raw/`, same regex | raw_tar | L |
| R/stages.R:45 | `manifest.parquet` | raw_manifest | W |
| R/stages.R:100-101 | local `{OUTPUT_DIR}/raw/` (KEEP_LOCAL) | raw_tar (local) | – |
| R/stages.R:116 | `file.path(S3_PREFIX_RAW, basename(tar_path))` → `raw/SNODAS_{compact_date}.tar` | raw_tar | W |
| R/stages.R:131-135, :144 | `manifest.parquet` (stores `tar_name`) | raw_manifest | R, W |
| R/stages.R:159, :169 | `raw/SNODAS_{compact_date}.tar` | raw_tar | R |
| R/stages.R:203 | `snodas_cog_key(date, short_name)`, every product | raw_cog | W |
| R/stages.R:220-221, :235 | `manifest.parquet` | raw_manifest | R, W |
| R/snodas_raw.R:227-228, :303-304, :326 | local manifest and `{OUTPUT_DIR}/cogs/{date}/{filename}`; the manifest stores file names (`tar_filename`, `cog_{var}`), not keys | raw_manifest, raw_cog | doc |

### Daily stage 3: normals inputs and percentiles

| file:line | template as written | artifact | op |
|---|---|---|---|
| R/calc_snodas_normals.R:50-52 | `s3_sync_down(file.path(S3_PREFIX_COGS, format(rd)), …, include = snodas_cog_filename(rd, "swe"))`, rd = reference dates | raw_cog (`var = "swe"`) | L, R |
| R/calc_zonal_normals.R:91-93 | the same | raw_cog | L, R |
| R/calc_snodas_normals.R:29, :36-38 | local `{OUTPUT_DIR}/normals/gridded/{flavor}/{date}` | normals_grid folder | – |
| R/calc_snodas_normals.R:95 | `paste0(d, "_ecdf_", i, ".tif")`, i ∈ mean, quantiles | normals_grid | W (via upload) |
| R/calc_snodas_normals.R:98-100 | `{d}_ecdf_median.tif`, `{d}_ecdf_provenance.json` | normals_grid, provenance_grid | W |
| R/calc_snodas_normals.R:86, :115 | `{d}_zig_params.tif` | normals_grid (`stat = "params"`) | W |
| R/calc_snodas_normals.R:87 | `{ZG}/zig_smooth/{d}/{d}_zig_smooth_params.tif` (local, read if present) | normals_grid | R |
| R/calc_snodas_normals.R:120-124 | `{d}_zig_{mean,quantiles,median}.tif`, `{d}_zig_provenance.json` | normals_grid, provenance_grid | W |
| R/calc_snodas_normals.R:135 | `{suffstats_dir}/rows_{row:%04d}/{d}.parquet` | normals_build (`file = "suffstats/…"`) | W |
| R/calc_snodas_normals.R:175-207 | `{d}_{flavor}_swe_{ptile,standardized}.tif` | percentile_grid | W |
| R/calc_zonal_normals.R:48-51 | local `{ZW}/{raw,ecdf,zig,zig_smooth}/{d}` | (folders) | – |
| R/calc_zonal_normals.R:53-54 | `{d}_raw_{hypsomeswe,swe}_means.parquet` | means_day | W |
| R/calc_zonal_normals.R:55-60 | `{d}_{flavor}_{hypsomeswe,swe}_normals.parquet` | normals_table_day | W |
| R/calc_zonal_normals.R:343-345 | `{d}_{ecdf,zig}_provenance.json` | provenance_day | W |
| R/stages.R:263, :272, :276 | local `{OUTPUT_DIR}/cogs`, `…/normals/gridded`, `…/normals/zonal/wbd` | (local) | – |
| R/stages.R:300-304 | `{ZG}/{ecdf,zig}/{date}/*` (fallback normals, whole folder) | normals_grid, provenance_grid | W |
| R/stages.R:310-315 | `{ZW}/{raw,ecdf,zig}/{date}/*` (fallback zonal) | normals_table_day, provenance_day, means_day | W |
| R/stages.R:360 | `gridded <- \(flavor, file) file.path(S3_PREFIX_NORMALS_GRIDDED, flavor, d, paste0(d, file))` | normals_grid, provenance_grid | – |
| R/stages.R:361 | `gridded("ecdf", "_ecdf_provenance.json")` | provenance_grid | R |
| R/stages.R:362 | `gridded("zig", "_zig_params.tif")` | normals_grid | R |
| R/stages.R:373-376 | `{ZG}/{zig,zig_smooth}/{date}/{date}_{flavor}_params.tif` | normals_grid | R |
| R/stages.R:378-380 | `s3_sync_down` of `{ZW}/{ecdf,zig,zig_smooth}/{date}` | normals_table_day, provenance_day | L, R |
| R/stages.R:390-393 | `{ZG}/{flavor}/{date}/` include `*_swe_ptile.tif`, `*_swe_standardized.tif` | percentile_grid | W |
| R/stages.R:394-397 | `{ZW}/{raw,ecdf,zig,zig_smooth}/{date}/*.parquet` (rewritten with the day's percentiles) | normals_table_day, means_day | W |
| R/stages.R:432-435, :454 | `file.path(S3_PREFIX_NORMALS_ZONAL_WBD, "observed", paste0("wy", wy, "_swe.parquet"))` | percentiles (`type = "swe"`) | R, W |
| R/stages.R:437-440 | `file.path({ZW}, fl, format(d), paste0(d, "_", fl, "_swe_normals.parquet"))` | normals_table_day | R |

### Daily stage 5 (plots), stage 6 (latest/)

| file:line | template as written | artifact | op |
|---|---|---|---|
| R/stages.R:507, :516, :587 | `file.path("cache", "plot_axes", paste0("wy", wy, "_hypsomeswe.parquet"))` | cache `plot_axes/wy{wy}_hypsomeswe.parquet` | R, W |
| R/stages.R:511-513 | `file.path({ZG}, "zig_smooth", paste0("wy", wy), "build.json")` | normals_grid_build | R |
| R/stages.R:523-524 | local `{ZW}/{flavor}/{date}/{date}_{flavor}_hypsomeswe_normals.parquet` | normals_table_day (local) | R |
| R/stages.R:525-529 | `aws s3 sync s3://{bucket}/{ZW}/{flavor}/` → `{OUTPUT_DIR}/plot_axes_work/{flavor}`, include `{date}/*_{flavor}_hypsomeswe_normals.parquet` (local path does **not** mirror the key) | normals_table_day | L, R |
| R/stages.R:628-631 | `{ZW}/{flavor}/{date}/{date}_{flavor}_hypsomeswe_normals.parquet` | normals_table_day | R |
| R/stages.R:643-648 | `aws s3 sync s3://{bucket}/{BZ}/wy{wy}/`, include `*_swe.parquet` or `{zone}_swe.parquet` | normals_by_subject | L, R |
| R/stages.R:651-653 | `{ZW}/observed/wy{wy}_swe.parquet` | percentiles | R |
| R/stages.R:677, :703 | local `{OUTPUT_DIR}/plots/{date}/{flavor}/{type}/usdm/{huc}.png` | plot | W (:748) |
| R/stages.R:742 | `path = "{flavor}/{type}/{style}/{huc}.png"` inside index.json | plot | doc |
| R/stages.R:747-749 | `paste0("s3://", S3_BUCKET, "/plots/", format(date))`, sync `--exclude index.json` | plot | W |
| R/stages.R:750 | `paste0(dest, "/index.json")`, written last | plot_index | W |
| R/stages.R:780-791 | `s3_copy_strip_date(src, dest_prefix)`: `Key = paste0(dest_prefix, "/", stripped)`, stripping `^\d{4}-\d{2}-\d{2}_` and `_\d{8}(?=\.)` | latest_* | W |
| R/stages.R:795-798 | list `latest/` and delete **everything**, including `latest/README.md` | latest_*, readme | L, D |
| R/stages.R:802-803 | `snodas_cog_key(date, "swe")` → `latest/cogs/snodas_swe.tif` | raw_cog → latest_raw | R, W |
| R/stages.R:805-811 | list `{ZG}/{flavor}/{date}/`; copy each → `latest/cogs/{flavor}_{stat}.tif`, `…/{flavor}_swe_{ptile,standardized}.tif`, `…/{flavor}_provenance.json` (keys from the listing) | normals_grid → latest_grid; percentile_grid → latest_percentile_grid; provenance_grid → latest_grid_provenance | L, R, W |
| R/stages.R:814-820 | list `{ZW}/{raw,ecdf,zig,zig_smooth}/{date}/`; copy → `latest/zonal/{flavor}_{type}_normals.parquet`, `raw_{type}_means.parquet`, `{flavor}_provenance.json` | normals_table_day → latest_normals_table_day; means_day → latest_means_day; provenance_day → latest_provenance_day | L, R, W |
| R/stages.R:825, :831 | `plots_key <- paste0("plots/", format(date))` in the manifest; HEAD `…/index.json` | plot_index | R, doc |
| R/stages.R:828 | `files = copied_keys` in the manifest | latest_* | doc |
| R/stages.R:835-841 | `paste0(S3_PREFIX_LATEST, "/manifest.json")` | latest_manifest | W |
| viz.R:58 | local `{OUTPUT_DIR}/{ZW}/{flavor}/{date}` (cleanup) | (local) | – |

### Reference data (`cache/data/`)

The local copy is `data/{name}` in the working directory (`/pipeline`), not under
`OUTPUT_DIR`. Each key is `paste0("cache/data/", basename(out_file))`. All are
`cache` (`file = "data/…"`) except `wbd_zones.parquet`, which is `subjects`.

| file:line | key | artifact | op |
|---|---|---|---|
| R/snodas_reference.R:7, :9, :41 | `cache/data/snodas_mask.tif` | cache | R, W |
| R/snodas_reference.R:53, :55, :89 | `cache/data/snodas_elevation.tif` | cache | R, W |
| R/wbd.R:9, :11, :31 | `cache/data/wbd_huc8.parquet` | cache | R, W |
| R/wbd.R:44, :48, :75 | `cache/data/wbd_huc8.tif` | cache | R, W |
| R/wbd.R:45, :49, :77 | `cache/data/wbd_huc8.tif.aux.xml` (`paste0(s3_key, ".aux.xml")`) | cache | R, W |
| R/wbd.R:122, :124, :145 | `cache/data/snodas_domain.fgb` | cache | R, W |
| R/wbd.R:159, :161, :236 | `cache/data/wbd_huc8_clipped.parquet` | cache | R, W |
| R/wbd.R:253, :255, :287 | `cache/data/wbd_zones.parquet` | subjects | R, W |
| R/wbd.R:304, :306, :328 | `cache/data/wbd_huc8_simple.parquet` | cache | R, W |
| R/wbd.R:342, :344, :369 | `cache/data/wbd_names.parquet` | cache | R, W |
| R/wbd.R:379-404 | `cache/data/fgb/huc{2,4,6,8}.fgb` (local default `"s3/cache/data/fgb"`; manual only) | cache | W |

### Yearly build (R/normals_annual.R)

| file:line | template as written | artifact | op |
|---|---|---|---|
| :141 | `snodas_cog_key(as_date("{wy-1}-09-30"), "swe")` | raw_cog | R |
| :160-166 | for prefix in `file.path(S3_PREFIX_NORMALS_BUILD, "current")`, `normals_build_prefix(wy)`: `{days,materialize,observed_batches,blocks,observed,build}.json` | normals_build_current, normals_build (`file = "days.json"` …) | W |
| :181-182, :191-192 | `{NB}/wy{wy}/suffstats/rows_{row:%04d}/{date}.parquet` | normals_build (`file = "suffstats/…"`) | W |
| :185-187 | `{ZG}/{ecdf,zig}/{date}/*` | normals_grid, provenance_grid | W |
| :188-190 | `{ZW}/{raw,ecdf,zig}/{date}/*` | normals_table_day, provenance_day, means_day | W |
| :202 | list `{NB}/wy{wy}/suffstats/` | normals_build | L |
| :220, :227-228 | `{NB}/wy{wy}/suffstats/rows_{row:%04d}` | normals_build | L, R |
| :252, :256, :267 | local `{NB}/wy{wy}/tiles/coef/rows_{row}.tif`, `tiles/params/{date}/rows_{row}.tif` | normals_build (local) | – |
| :269 | `{NB}/wy{wy}/tiles/…` (whole local `tiles/`) | normals_build | W |
| :280-282 | `{ZW}/raw/{date}` for every date of the year | means_day | L, R |
| :321-326 | local `{ZW}/zig_smooth/{date}/{date}_zig_smooth_{swe,hypsomeswe}_normals.parquet`, `…_provenance.json` | normals_table_day, provenance_day | – |
| :331-332 | `{ZW}/zig_smooth/…` (whole local tree) | normals_table_day, provenance_day | W |
| :347 | local `{NB}/wy{wy}/by_zone` (never uploaded) | (local) | – |
| :348, :409 | local `{BZ}/wy{wy}/{zone}_{level}.parquet` | normals_by_subject | – |
| :375-378 | `aws s3 sync s3://{bucket}/{ZW}/{flavor}/`, include `{YYYY-MM}-*/*_{flavor}_{level}_normals.parquet` (month glob) | normals_table_day | L, R |
| :419 | `s3_sync_up(out, file.path(S3_PREFIX_NORMALS_BY_ZONE, paste0("wy", wy)))` | normals_by_subject | W |
| :427-428 | `{NB}/wy{wy}/tiles/coef` | normals_build | L, R |
| :434-450 | `file.path(OUTPUT_DIR, {ZG}, "zig_smooth", paste0("wy", wy))`: `zig_smooth_coef.tif`, `zig_smooth_diagnostics.tif`, `zig_smooth_basis.csv`, `zig_smooth_model.json` | normals_grid_coef, _diagnostics, _basis, _model | W |
| :459-460 | `{NB}/wy{wy}/tiles/params/{date}` | normals_build | L, R |
| :468-483 | `{ZG}/zig_smooth/{date}/{date}_zig_smooth_{params,mean,quantiles,median}.tif`, `…_provenance.json` | normals_grid, provenance_grid | W |
| :514-536 | sync `s3://{bucket}/{ZW}/raw` → local, include `{date}/*` | means_day | L, R |
| :522, :540 | sync local → `s3://{bucket}/{ZW}/{raw,ecdf,zig}`, include `{date}/*` | means_day, normals_table_day, provenance_day | W |
| :546 | the same for `{ecdf,zig,zig_smooth}` | normals_table_day, provenance_day | W |
| :557 | `{NB}/wy{wy}/observed.json` | normals_build | R |
| :574-576 | `{ZG}/zig_smooth/wy{wy}/build.json` | normals_grid_build | W |
| :577 | `s3_delete_prefix(normals_build_prefix(wy))` | normals_build | L, D |

### Animations (R/animate.R)

| file:line | template as written | artifact | op |
|---|---|---|---|
| :110-112 | local `plots/{date}/{flavor}/hypsomeswe/usdm`, `plots/{date}/index.json` | plot, plot_index | – |
| :116 | `plots/{date}/index.json` for every date of the year | plot_index | R |
| :129 | sync `s3://{bucket}/plots/{date}/{flavor}/hypsomeswe/usdm` | plot | L, R |
| :149-152 | `{ZW}/{flavor}/{wy}-09-30/{wy}-09-30_{flavor}_hypsomeswe_normals.parquet` | normals_table_day | R |
| :156-158 | local `cache/plot_axes/wy{wy}_hypsomeswe.parquet` | cache | R |
| :183-186 | local `{OUTPUT_DIR}/animations/wy{wy}/{flavor}/hypsomeswe/usdm/{huc}.mp4` | animation | W (:213) |
| :206 | `path = "hypsomeswe/usdm/{huc}.mp4"` inside index.json | animation | doc |
| :212-213 | `paste0("s3://", S3_BUCKET, "/", S3_PREFIX_ANIMATIONS, "/wy", wy, "/", flavor)`, sync `--delete --exclude index.json` | animation | W, D |
| :214 | `paste0(dest, "/index.json")` | animation_index | W |

### Scripts

| file:line | template as written | artifact | op |
|---|---|---|---|
| scripts/backfill-figures.sh:16, :35 | HEAD `plots/{date}/index.json` | plot_index | R |
| scripts/backfill-figures-local.sh:29, :50 | `BUCKET="mco-snodas"`; HEAD `plots/{date}/index.json` | bucket, plot_index | R |
| scripts/backfill-figures-local.sh:92 | passes `S3_BUCKET=$BUCKET`, `WORK_DIR=/work` | bucket | – |
| scripts/backfill-figures-offline.sh:44, :83 | `BUCKET="mco-snodas"`, `zonal="normals/zonal/wbd"` | bucket | – |
| scripts/backfill-figures-offline.sh:91-95 | sync `s3://$BUCKET/$zonal/{flavor}/`, include `{YYYY-MM}-*/*_{flavor}_hypsomeswe_normals.parquet` | normals_table_day | L, R |
| scripts/backfill-figures-offline.sh:97-98 | `{BZ}/wy{wy}/`, include `*_swe.parquet` | normals_by_subject | L, R |
| scripts/backfill-figures-offline.sh:99 | `{ZW}/observed/wy{wy}_swe.parquet` | percentiles | R |
| scripts/backfill-figures-offline.sh:100-101 | `normals/gridded/zig_smooth/wy{wy}/build.json` | normals_grid_build | R |
| scripts/backfill-figures-offline.sh:103 | `cache/plot_axes/wy{wy}_hypsomeswe.parquet` | cache | R |
| scripts/backfill-figures-offline.sh:106-107 | `cache/data/wbd_names.parquet`, `cache/data/wbd_zones.parquet` → `$DATA/{name}`, mounted at `/pipeline/data/` | cache, subjects | R |
| scripts/backfill-figures-offline.sh:217, :223-224 | `plots/{date}` sync `--delete --exclude index.json`, then `plots/{date}/index.json` | plot, plot_index | W, D |
| scripts/backfill-median.sh:21-22, :37-38, :48 | `normals/gridded/{flavor}/{date}/{date}_{flavor}_median.tif` | normals_grid (`stat = "median"`) | R, W |
| scripts/backfill-median.sh:43 | `…/{date}_{flavor}_quantiles.tif` | normals_grid | R |
| scripts/backfill-median.sh:60-62 | list `normals/gridded/{flavor}/` with delimiter `/` (date folders, dropping `wy*`) | normals_grid | L |
| scripts/publish-bucket-readmes.sh:7 | `s3-docs/**/README.md` → `s3://mco-snodas/` + the same relative path | readme | W |

### Infrastructure and docs

| file:line | template as written | artifact | op |
|---|---|---|---|
| terraform/variables.tf:65-68 | `s3_bucket_name` default `"mco-snodas"` | bucket | – |
| terraform/variables.tf:133-137 | `normals_build_prefix` default `"normals/build"` | normals_build_current | – |
| terraform/variables.tf:141-144 | `shadow_s3_bucket_name` default `"mco-snodas-test"` | bucket (shadow) | – |
| terraform/normals-annual.tf:25 | `normals_lists = "${var.normals_build_prefix}/current"` | normals_build_current | – |
| terraform/normals-annual.tf:146-155 | Step Functions ItemReader `Key = "${normals_lists}/{days,blocks,materialize,observed_batches}.json"`, `Bucket = var.s3_bucket_name` | normals_build_current | R |
| terraform/normals-annual.tf:279 | IAM `${bucket_arn}/${var.normals_build_prefix}/*` | normals_build_current, normals_build | – |
| terraform/s3.tf:72 | lifecycle rule prefix `plots/` | plot, plot_index | – |
| terraform/ecs.tf:51-53 | `S3_BUCKET = var.s3_bucket_name`, `WORK_DIR=/tmp/snodas` | bucket | – |
| terraform/shadow.tf:230-232 | `S3_BUCKET = aws_s3_bucket.shadow.bucket` | bucket (shadow) | – |
| docker-compose.yml:9-10 | `S3_BUCKET: mco-snodas`, `WORK_DIR: /pipeline/s3` | bucket | – |
| CONSUMERS.md:20-24, :36-50, :79, :88, :100 | `latest/manifest.json`; `cogs/{d}/snodas_{product}_{ymd}.tif`; `normals/gridded/{flavor}/{d}/{d}_{flavor}_{swe_ptile,swe_standardized,quantiles}.tif` and `…_provenance.json`; `normals/zonal/wbd/{flavor}/{d}/{d}_{flavor}_{swe,hypsomeswe}_normals.parquet`; `…/by_zone/wy{YYYY}/{huc}_{swe,hypsomeswe}.parquet`; `…/observed/wy{YYYY}_swe.parquet`; `cache/data/fgb/huc{2,4,6,8}.fgb`; `cache/data/wbd_zones.parquet`; `cache/data/snodas_domain.fgb`; `plots/{d}/{flavor}/{swe,hypsomeswe}/usdm/{huc}.png`; `plots/{d}/index.json`; `animations/wy{YYYY}/{flavor}/hypsomeswe/usdm/{huc}.mp4` and `…/{flavor}/index.json`. Declares the paths stable. | (most) | doc |
| README.md:19-34, :94, :112 | stage → prefix summary; `normals/build/current/`; `cache/plot_axes/` | (several) | doc |
| s3-docs/README.md:14-22 | top-level folders, including `manifest.parquet` | (folders) | doc |
| s3-docs/cogs/README.md:8, :23 | `<YYYY-MM-DD>/snodas_<product>_<YYYYMMDD>.tif`, `../manifest.parquet` | raw_cog, raw_manifest | doc |
| s3-docs/raw/README.md:3 | `SNODAS_<YYYYMMDD>.tar` | raw_tar | doc |
| s3-docs/latest/README.md:11-20 | `latest/cogs/snodas_swe.tif`, `cogs/<flavor>_<file>`, `zonal/<flavor>_<table>.parquet`, `"plots": "plots/{d}"` | latest_* | doc |
| s3-docs/normals/README.md:11-14 | `gridded/<flavor>/`, `zonal/wbd/<flavor>/`, `zonal/wbd/raw/`, `build/` | (folders) | doc |
| s3-docs/normals/gridded/README.md:8-33 | `<flavor>/<d>/<d>_<flavor>_{mean,quantiles,median,params,swe_ptile,swe_standardized}.tif` and provenance; `zig_smooth/wy<YYYY>/{zig_smooth_coef.tif, …, build.json}` | normals_grid*, percentile_grid, provenance_grid | doc |
| s3-docs/normals/zonal/wbd/README.md:14-21 | dated tables, provenance, `raw/<d>/<d>_raw_{swe,hypsomeswe}_means.parquet`, `by_zone/…`, `observed/…` | normals_table_day, provenance_day, means_day, normals_by_subject, percentiles | doc |
| s3-docs/plots/README.md:9, :22 | `<d>/<flavor>/<type>/usdm/<huc>.png`, `<d>/index.json` | plot, plot_index | doc |
| s3-docs/animations/README.md:5, :9, :18 | `wy<YYYY>/<flavor>/hypsomeswe/usdm/<huc>.mp4`, `wy<YYYY>/<flavor>/index.json` | animation, animation_index | doc |
| s3-docs/cache/README.md:5-15 | the state files and every `data/` file | cache, subjects | doc |

No S3 keys in: R/plot.R, R/utils.R, R/snodas_setup.R, scripts/test_distributions.R,
scripts/ecr-push.sh, scripts/run_local.sh, scripts/parity/check-identical.sh,
.github/workflows/docker-publish.yml, the Dockerfile.

---

## Shared: scripts/parity/seed.sh

Byte-identical in both repositories. It copies production inputs to `mco-{project}-test`.

| line | template as written | artifact | op |
|---|---|---|---|
| :90-92 | `SRC="mco-${PROJECT}"`, `DST="mco-${PROJECT}-test"` | bucket | – |
| :102-104 | `list_prefix`: `list-objects-v2 --prefix "$1"` | (any) | L |
| :121-126 | `add_key_asof`: `list-object-versions --prefix "$1"` | (any) | L |
| :144-146 | `raw/SNODAS_${D0C}.tar` | raw_tar | L |
| :150 | `cache/dates_state.parquet`, `cache/normals_state.parquet`, `manifest.parquet` (as of a time) | cache, raw_manifest | R |
| :153-154 | `raw/SNODAS_` prefix; regex, `substr($1, 12, 8) >= d0` | raw_tar | L, R |
| :157-159 | `cache/data/{snodas_mask.tif, snodas_elevation.tif, wbd_huc8.tif, wbd_huc8.tif.aux.xml, wbd_names.parquet, wbd_zones.parquet}` | cache, subjects | R |
| :167 | `cogs/${rd}/snodas_swe_${rd//-/}.tif` | raw_cog | R |
| :170 | `normals/gridded/${fl}/${d}/` minus `_swe_(ptile\|standardized)\.tif$` | normals_grid, provenance_grid | L, R |
| :171 | `normals/zonal/wbd/${fl}/${d}/` | normals_table_day, provenance_day | L, R |
| :176 | `normals/zonal/wbd/observed/wy${wy}_swe.parquet` | percentiles | R |
| :177 | `normals/gridded/zig_smooth/wy${wy}/build.json` | normals_grid_build | R |
| :178 | `cache/plot_axes/wy${wy}_hypsomeswe.parquet` | cache | R |
| :179 | `normals/zonal/wbd/by_zone/wy${wy}/`, filtered to `*_swe.parquet` | normals_by_subject | L, R |
| :184 | `archive/snotel.parquet` | raw (snotel) | R |
| :188 | `plots/${d}/index.json` | plot_index (snotel) | R |
| :191 | `normals/reference/wy${wy}.parquet` | reference (snotel) | R |
| :193 | `normals/${p}/wy${wy}/normals.parquet`, p ∈ 30yr, snodas, por | normals_table (snotel) | R |
| :194 | `normals/${p}/wy${wy}/provenance.json` | provenance (snotel) | R |
| :217 | `aws s3 rm "s3://${DST}" --recursive` (`--wipe`, test bucket only) | (all) | D |
| :223, :225 | copy `s3://${SRC}/$1` → `s3://${DST}/$1` | (all) | W (test) |

The header (lines 26-56) describes the same keys.

---

## What was awkward to express

1. **Date-keyed normals (mco-snodas).** Gridded and zonal normals sit in a folder for each
   flavor and date (`normals/gridded/{flavor}/{date}/{date}_{flavor}_{stat}.tif`).
   - The v1 equivalent is keyed by period and day.
   - `normals_grid`, `provenance_grid` and `percentile_grid` keep the v1 IDs, because one v0
     object is still one v1 object.
   - The zonal tables (one file per flavor × date × type in v0, one per period in v1) get
     v0-only IDs: `normals_table_day`, `provenance_day`, `means_day`.
2. **Normals and percentile grids share a folder.** v0 needs per-artifact `formats` to keep
   `stat` apart: `normals_grid` is mean, median, quantiles or params; `percentile_grid` is
   `swe_{ptile,standardized}`. The resolver supports `formats` for this. The same split
   applies to `latest/cogs/`.
3. **latest/ names.**
   - mco-snotel: `latest/observed_{role}.parquet` is the percentiles under an old name. The
     v0 `values: {artifact: {percentiles: observed}}` map handles it, so
     `layout_key("latest_copy", artifact = "percentiles", role = …)` works in v0 and v1.
   - mco-snotel: `latest/stations.parquet` has no v1 equivalent (`latest_subjects`, v0 only).
   - mco-snodas: latest keys are made by regex-stripping listed source keys
     (stages.R:780-820). v0 gives each kind its own artifact, so 2B builds them from
     artifacts instead of listings.
4. **Keys from listings.** mco-snodas Stage 6, `read_pipeline_state` (`raw/`, the whole
   `cogs/` tree), the annual `suffstats` grouping and `backfill-median.sh` derive keys from
   listings. The resolver gives `layout_prefix()` for the listing and `layout_match()` /
   `layout_classify()` to parse the results.
5. **Prefix artifacts with free-form contents.** `cache/`, `normals/build/wy{wy}/` and
   `normals/build/current/` hold files the code names itself (state files, `data/`,
   `plot_axes/`, suffstats rows and tiles, work lists). They are prefix artifacts:
   `layout_key("cache", file = "state.parquet")`.
6. **`cache/data/wbd_zones.parquet` is public** (CONSUMERS.md) but sits under `cache/`. In
   v0 it is the `subjects` artifact (cache class `none`, as today).
7. **Shell globs encode the layout**: `{YYYY-MM}-*/*_{flavor}_{level}_normals.parquet`,
   `*_swe.parquet`, `*_swe_ptile.tif`. The resolver gives prefixes and keys, not globs. 2B
   either keeps a glob next to `layout_prefix()` or lists and filters with `layout_match()`.
8. **Local paths that don't mirror keys**: `cache/data/*` lives at `./data/`;
   `plot_axes_work/`; the offline backfill's `$DATA/`. Everything else is
   `{OUTPUT_DIR}/{key}`, which `VIZ_OFFLINE` relies on.
9. **Objects no code writes.** `animations/sy2026/` (7,933 MP4s and 3 index files, spec
   section 15 item 3) gets the legacy artifacts `animation_sy` and `animation_index_sy`, so every
   object in the bucket has an artifact. The bucket has no `animations/wy*` yet, although that
   is what `R/animate.R` writes.
10. **Stage 6 in mco-snodas deletes `latest/README.md`** every night along with the rest of
   `latest/` (step 0G changes this).
11. **Two `build.json` files**: the build stamp under `normals/build/…` (written, never read)
    and the completion stamp `normals/gridded/zig_smooth/wy{wy}/build.json` (read).
12. **Prefixes with and without `/`.** mco-snodas helpers take prefixes without a trailing
    `/` and join with `/`. mco-snotel's manifest stores folders without one. The resolver
    returns `/`-terminated prefixes; `layout_prefix(…, slash = FALSE)` drops it.
13. **SNODAS reference years on Sep 30.** The yearly build uses the dates d − 0…30 years,
    from 2003-09-30 and before d's water year. So for Sep 30 of WY ≤ 2033 the record
    includes WY2003, one year more than the `snodas` role (WY2004 onward). This is a
    day-level detail of the method, not the layout; no key carries it.
14. **mco-snotel `period_years()` counts down** when its first year is after its last
    (`2010:2002`), e.g. `por` for a station whose record starts after W. The resolver returns
    no years there.
