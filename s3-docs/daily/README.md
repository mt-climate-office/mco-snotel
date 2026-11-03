# SNOTEL SWE percentiles and plots by date

Each day's observed SWE against its water year's normals (`../normals/`). `<period>` is the
water year's period for a role: in WY2027, `wy2004-2026` (`snodas`), `wy1997-2026` (`30yr`),
`wy1991-2020` (`noaa`) and `wypor-2026` (`por`). A WY2026 date is under WY2026's periods,
e.g. `wy2004-2025`.

| Path | Contents |
|------|----------|
| `percentiles/<period>/percentiles_<period>_wy<YYYY>.parquet` | Every station's observed SWE and percentiles for water year `<YYYY>`, to date |
| `plots/<period>/<YYYY-MM-DD>/` | The date's plots; see `plots/README.md` |
| `latest/` | Copies of this water year's percentiles tables, with `manifest.json`; see `latest/README.md` |

The percentiles table of the current water year is rewritten whole every day, since NRCS
edits recent values. It is sorted by flavor, date and triplet, so a reader that uses
row-group statistics can skip most of it to fetch one date. Rows exist only for dates with
SWE.

## Columns

| Column | Contents |
|--------|----------|
| `flavor` | `empirical`, `fitted` or `smoothed` |
| `date` | Date |
| `triplet` | Station |
| `swe` | Observed SWE, in |
| `swe_ptile` | Observed SWE's percentile, 0–100, to 0.01 |
| `swe_standardized` | Standardized anomaly, z, clamped to ±4 |

See `../normals/README.md` for how percentiles are computed. Join to a station's normals on
`flavor`, `triplet` and the month and day of `date`.
