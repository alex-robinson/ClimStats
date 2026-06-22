# ClimStats

A Julia package for retrieving climate data for a single location and computing
indices from it — **ERA5 reanalysis** for the past and **CMIP6 projections** for
the future. Write a place name, get back the data *and* a figure.

```julia
using ClimStats
using CairoMakie        # a Makie backend (CairoMakie for files, GLMakie for windows)

fig = climate_timeseries("Berlin, Germany"; threshold = 30)
save("berlin_hot_days.png", fig)
```

ERA5 history and the Open-Meteo CMIP6 ensemble are fetched live from the free,
key-less Open-Meteo APIs on first use, then **cached on disk** so the same series
is never re-downloaded (see [Caching](caching.md)). See the
[README](https://github.com/alex-robinson/ClimStats) for the full tour — indices,
bias correction, ensembles and SSP scenarios. These docs focus on **caching**,
the **temperature climatology** figures, and the **current-year nowcast**.

## Contents

```@contents
Pages = ["caching.md", "climatology.md", "nowcast.md"]
Depth = 2
```
