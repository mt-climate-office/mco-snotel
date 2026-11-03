# Latest SNOTEL data

This water year's percentiles tables, one per role, replaced daily. Read `manifest.json`
first: it gives the newest date with SWE and the folders behind each role.

```json
{
  "layout_version": 1,
  "date": "2026-11-01",
  "water_year": 2027,
  "updated": "2026-11-02T19:39:08Z",
  "archive": "raw/snotel_wy2027.parquet",
  "files": ["daily/latest/percentiles_snodas.parquet", "daily/latest/percentiles_30yr.parquet", "…"],
  "normals": {"snodas": "normals/wy2004-2026", "30yr": "normals/wy1997-2026", "noaa": "normals/wy1991-2020", "por": "normals/wypor-2026"},
  "plots": {"snodas": "daily/plots/wy2004-2026/2026-11-01"}
}
```

| File | Contents |
|------|----------|
| `percentiles_<role>.parquet`, `<role>` = `snodas`, `30yr`, `noaa`, `por` | Every station's observed SWE and percentiles for the water year, to date (see `../README.md`) |

`archive` is the water year's daily data file. `normals` gives each role's normals folder
for the water year. `plots`, when present, gives each plotted role's folder of that date's
plots. Station metadata is in `../../stations.parquet`.

Files here are overwritten daily, and a CDN copy can lag the update. To pin a water year,
use the dated paths in `../percentiles/`.
