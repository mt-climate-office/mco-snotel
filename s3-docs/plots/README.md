# SNOTEL station SWE plots

One seasonal SWE plot per station, normals period and flavor, for each date: the water
year's normals (Oct 1–Sep 30; "WY" in the legend) in USDM-style percentile classes
(D4–D0 drought, W0–W4 pluvial), the median dashed, this year's SWE, and the likely range
for the rest of the year (gray, dotted edges: the outlook's 10th–90th percentile; see
`../normals/`), in inches. They use the design of the SNODAS watershed plots at
`data2.climate.umt.edu/snodas/plots/`.

## Layout

`<YYYY-MM-DD>/<period>/<flavor>/swe/usdm/<station>.png`: 1500 × 1000 px, 8-bit (palette)
PNG. Every plot uses the same 256 colours as the SNODAS plots, so shared elements such as
legends match exactly.

`<station>` is the station triplet with `_` for `:` (`901_MT_SNTL`). `<period>` is `30yr`,
`snodas` or `por` (see `../normals/`); the daily run plots `snodas`, and other periods
are plotted on request. `<flavor>` is `ecdf` (Empirical History), `zig` (Fitted History) or
`zig_smooth` (Smoothed History). A station's three flavors share their SWE axis, and every
plot has the same frame, so they can be swapped in place. Every station with SWE in the
water year through the date is plotted, including stations retired since; stations with too
short a record show their SWE without normals.

`<YYYY-MM-DD>/index.json` lists the periods, flavors, path template and any stations that
failed. It is written last: if it exists and lists a period, that period's plots for the
date are complete.

