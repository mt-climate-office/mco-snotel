# Latest SNOTEL data

This water year's tables, replaced daily. Read `manifest.json` first: it gives the newest
date with SWE and lists every file.

```json
{
  "date": "2026-10-29",
  "water_year": 2027,
  "updated": "2026-10-30T16:20:11Z",
  "archive": "archive/snotel.parquet",
  "files": ["latest/stations.parquet", "latest/observed_30yr.parquet", "latest/outlook_30yr.parquet", "…"],
  "normals": {"30yr": "normals/30yr/wy2027", "snodas": "normals/snodas/wy2027", "por": "normals/por/wy2027"},
  "outlook": {"30yr": "normals/30yr/outlook/wy2027/2026-10-29.parquet", "…": "…"},
  "plots": "plots/2026-10-29"
}
```

| Path | Contents |
|------|----------|
| `stations.parquet` | Station metadata (see `../stations/`) |
| `observed_<period>.parquet` | Every station's observed SWE and percentiles for the water year, to date (see `../normals/`) |
| `outlook_<period>.parquet` | The outlook from `date` to Sep 30, every station (see `../normals/`) |

`normals` gives each period's normals folder for the water year; `outlook` gives each
period's dated outlook file, of which `outlook_<period>.parquet` is a copy. `plots`, when present, is
the folder of that date's plots (see `../plots/`). Files here are cached by the CDN for up
to an hour; the dated paths elsewhere in the bucket are cached for up to a day.
