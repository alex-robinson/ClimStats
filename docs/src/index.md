```@raw html
<p align="center">
  <img src="assets/logo.svg" alt="ClimStats logo" width="160" height="160">
</p>
```

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

Historical data default to **NASA POWER** (keyless, no request quota); pass
`source = :era5` for the Open-Meteo ERA5 archive instead. The CMIP6 ensemble is
fetched from the key-less Open-Meteo climate API. Everything is **cached on disk**
on first use so the same series is never re-downloaded (see [Caching](caching.md)),
and the example locations ship with a bundled offline fixture cache. See the
[README](https://github.com/alex-robinson/ClimStats) for the full tour — indices,
bias correction, ensembles and SSP scenarios. These docs focus on **caching**,
the **temperature climatology** figures, and the **current-year nowcast**.

## Contents

```@contents
Pages = ["caching.md", "climatology.md", "nowcast.md"]
Depth = 2
```
