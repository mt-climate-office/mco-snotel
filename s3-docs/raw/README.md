# SNOTEL daily data

`snotel_wy<YYYY>.parquet`: one row per station and day of water year `<YYYY>` (Oct 1 of the
year before to Sep 30), every SNOTEL station, sorted by `triplet` and `date`. Values are as
NRCS's Air and Water Database (AWDB) stores them, in inches and °F, each with its QC and QA
flags. Station metadata is in `../stations.parquet`.

The current water year's file is refetched from AWDB every day, since NRCS edits recent
values. The whole record is refetched once a year, on Oct 1. AWDB leaves out values NRCS has
marked suspect, so a value flagged later drops out at the next refetch that covers its date.

| Column | Contents |
|--------|----------|
| `triplet`, `site_id` | Station (see `../stations.parquet`) |
| `date` | Day, as AWDB stamps daily values (end of period) |
| `wteq` | Snow water equivalent, in |
| `snwd` | Snow depth, in |
| `prec` | Precipitation accumulated since Oct 1, in |
| `prcp` | Daily precipitation, in |
| `tmax`, `tmin`, `tavg` | Air temperature, °F |
| `<element>_qc` | NRCS QC flag, e.g. `V` valid, `E` edited, `K` estimated |
| `<element>_qa` | NRCS QA flag, e.g. `P` provisional, `R` reviewed |

Days with no value for any element are absent. The SWE normals treat negative `wteq` as
missing.

## Access

```python
import pandas as pd
url = "https://data2.climate.umt.edu/snotel/raw/snotel_wy2026.parquet"
x = pd.read_parquet(url, columns=["date", "wteq"], filters=[("triplet", "==", "901:MT:SNTL")])
```

```sql
-- DuckDB: several water years (HTTPS has no listing, so name each file)
SELECT date, wteq FROM read_parquet([
  'https://data2.climate.umt.edu/snotel/raw/snotel_wy2025.parquet',
  'https://data2.climate.umt.edu/snotel/raw/snotel_wy2026.parquet'])
WHERE triplet = '901:MT:SNTL' ORDER BY date;
```

The first file is `snotel_wy1963.parquet`.
