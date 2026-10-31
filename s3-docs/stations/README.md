# SNOTEL stations

`stations.parquet`: one row per SNOTEL station in NRCS's Air and Water Database, active and
retired, refreshed nightly.

| Column | Contents |
|--------|----------|
| `triplet` | NRCS station triplet, e.g. `901:MT:SNTL`. Tables elsewhere in the bucket key stations by it. |
| `station` | The triplet with `_` for `:`, as in file names (`901_MT_SNTL`) |
| `site_id` | NRCS station number |
| `state`, `network`, `name`, `county` | As NRCS lists them |
| `huc` | 12-digit HUC the station is in |
| `elevation_ft` | Elevation, feet |
| `latitude`, `longitude` | Decimal degrees |
| `begin_date`, `end_date` | Station record dates. Active stations have an end date of 2100-01-01. |
| `active` | Still reporting |
