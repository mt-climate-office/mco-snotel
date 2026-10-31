# SNOTEL — daily station data, SWE normals and percentiles

Daily data from every NRCS SNOTEL station, active and retired, with SWE normals,
percentiles and plots, processed by the Montana Climate Office. Updated nightly around
10 AM Mountain. Values are in inches and °F, as NRCS stores them.
Source and methods: [github.com/mt-climate-office/mco-snotel](https://github.com/mt-climate-office/mco-snotel).
Building an app on these data: see
[CONSUMERS.md](https://github.com/mt-climate-office/mco-snotel/blob/main/CONSUMERS.md).

## Layout

| Path | Contents |
|------|----------|
| `latest/` | This water year's observed SWE and percentiles, and the station list, with `manifest.json`. Start here. |
| `stations/` | Station metadata. |
| `archive/` | Daily SWE, snow depth, precipitation and air temperature for every station and day, with NRCS flags. |
| `normals/<period>/wy<YYYY>/` | Each water year's SWE normals for every station and day. |
| `normals/<period>/observed/` | Each water year's observed SWE and percentiles. |
| `plots/<YYYY-MM-DD>/` | Per-station seasonal SWE plots (PNG). |
| `cache/` | Pipeline state; not for use. |

`<period>` is the normals' reference period: `30yr` (the 30 water years before), `snodas`
(the years the SNODAS normals at `data2.climate.umt.edu/snodas/` use) or `por` (each
station's whole record). Each folder's `README.md` has the details.

## Access

```python
import pandas as pd
base = "https://data2.climate.umt.edu/snotel/"
stations = pd.read_parquet(base + "stations/stations.parquet")
obs = pd.read_parquet(base + "latest/observed_snodas.parquet")
obs[(obs.triplet == "901:MT:SNTL") & (obs.flavor == "zig_smooth")].tail()   # Stuart Mountain
```

```r
x <- arrow::read_parquet("https://data2.climate.umt.edu/snotel/latest/observed_30yr.parquet")
```

## Citation

USDA Natural Resources Conservation Service, National Water and Climate Center. SNOTEL
daily data, from the Air and Water Database REST API,
<https://wcc.sc.egov.usda.gov/awdbRestApi/>.
