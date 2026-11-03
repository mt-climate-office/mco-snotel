# SNOTEL station SWE plots

One seasonal SWE plot per station, period and flavor, for each date: the water year's
normals (Oct 1 to Sep 30; "WY" in the legend) in USDM-style percentile classes (D4–D0
drought, W0–W4 pluvial), the median dashed, and this year's SWE, in inches. They use the
design of the SNODAS watershed plots at `data2.climate.umt.edu/snodas/zonal/daily/plots/`.

## Layout

`<period>/<YYYY-MM-DD>/<flavor>/<station>_swe_<period>_<flavor>_<YYYY-MM-DD>.png`:
1500 × 1000 px, 8-bit (palette) PNG. Every plot uses the same 256 colours as the SNODAS
plots, so shared elements such as legends match exactly.

`<station>` is the station triplet with `_` for `:` (`901_MT_SNTL`). `<period>` is the
date's period for a role (see `../README.md`). The daily run plots the `snodas` role
(`wy2004-2026` in WY2027); other roles are plotted on request. `<flavor>` is `empirical`
(Empirical History), `fitted` (Fitted History) or `smoothed` (Smoothed History). A station's
three flavors share their SWE axis, and every plot has the same frame, so they can be swapped
in place. Every station with SWE in the water year through the date is plotted, including
stations retired since. Stations with too short a record show their SWE without normals.

`<period>/<YYYY-MM-DD>/index_<period>_<YYYY-MM-DD>.json` lists the periods, flavors, path
template and any stations that failed. It is written last: if it exists, that period's
plots for the date are complete.

Indexes for dates before 2026-11-01 were copied from layout v0. They still list the v0
flavor names (`ecdf`, `zig`, `zig_smooth`) and the v0 `path` template. Build plot paths from
the layout above, not from an index's `path`.
