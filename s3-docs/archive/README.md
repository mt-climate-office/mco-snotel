# SNOTEL daily archive

`snotel.parquet`: one row per station and day, every SNOTEL station's whole record, sorted
by `triplet` and `date`. Values are as NRCS's Air and Water Database (AWDB) stores them, in
inches and °F, each with its QC and QA flags. Station metadata is in `../stations/`.

The current water year is refetched from AWDB every day, since NRCS edits recent values,
and the whole record once a year, on Oct 1. AWDB leaves out values NRCS has marked suspect,
so a value flagged later drops out at the next refetch that covers its date.

| Column | Contents |
|--------|----------|
| `triplet`, `site_id` | Station (see `../stations/`) |
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

The file is over 100 MB. Read only the columns and rows you need:

```python
import pandas as pd
url = "https://data2.climate.umt.edu/snotel/archive/snotel.parquet"
x = pd.read_parquet(url, columns=["date", "wteq"], filters=[("triplet", "==", "901:MT:SNTL")])
```

```sql
-- DuckDB
SELECT date, wteq FROM 'https://data2.climate.umt.edu/snotel/archive/snotel.parquet'
WHERE triplet = '901:MT:SNTL' ORDER BY date;
```
