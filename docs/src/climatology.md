# Temperature climatology

How warm is it *for the time of year*, and how is that shifting? ClimStats reduces
the daily record to climatological **normals** — averages over a reference period,
per calendar day and per month — and compares the present (today's forecast, the
current year) and the future (a bias-corrected CMIP6 ensemble) against them.

The reference period is **1981–2010** by default, with **2011–2025** as a recent
comparison window and **2041–2050** drawn from the projection ensemble.

## The figures

The general script
[`examples/climatology.jl`](https://github.com/alex-robinson/ClimStats/blob/main/examples/climatology.jl)
renders all three figures for any location passed as an argument (defaulting to
Berlin). Run it from the package root with a Makie backend and internet access:

```julia
julia --project=docs examples/climatology.jl "Berlin, Germany"
```

### Today vs. the climatology

`climate_day_comparison` puts today's forecast next to the day-of-year normals:
a **black** bar for today's forecast `tmin`–`tmax`, a **grey** bar for the
1981–2010 reference, then **2011–2025** observed and **2041–2050** from the
bias-corrected CMIP6 ensemble. Each bar spans the climatological `tmin`–`tmax`
(smoothed over a ±3-day window) with a tick at the mean.

```julia
using ClimStats, CairoMakie

fig = climate_day_comparison("Berlin, Germany")
```

![Berlin: today vs. day-of-year climatology](assets/berlin_germany_today_vs_climate.png)

### Monthly seasonal cycle

`climate_monthly` draws every observed year as a faint grey line, highlights the
most recent complete year and the current (partial) year, and shades the
2041–2050 ensemble band.

```julia
fig = climate_monthly("Berlin, Germany")
```

![Berlin: monthly seasonal cycle](assets/berlin_germany_monthly_climatology.png)

### Daily seasonal cycle

`climate_daily` is the daily-resolution companion: a light band for the 1981–2010
central 95 % interval, a darker 2041–2050 ensemble band, the last and current
year as darker lines, and (online) the live forecast. Pass `spaghetti = true` to
overlay every year individually.

```julia
fig = climate_daily("Berlin, Germany"; spaghetti = true)
```

![Berlin: daily seasonal cycle](assets/berlin_germany_daily_climatology.png)

## Offline rendering

Every figure can be drawn from cached data alone — no network, with the live
forecast omitted — by passing `offline = true` or setting the `CLIMSTATS_OFFLINE`
environment variable. A location must have been fetched online at least once so
its data (and geocoding) are on disk.

```julia
fig = climate_daily("Berlin, Germany"; offline = true)   # cached data only
```

```julia
ClimStats.set_offline!(true)    # process-wide; returns the previous setting
```

## Computing normals directly

The figures are built on three tidy reducers; each returns a `DataFrame`.

```julia
data = era5_daily("Berlin, Germany"; start = Date(1981, 1, 1))

daily_climatology(data; var = :tmean, window = 3, period = (1981, 2010))  # per day-of-year
monthly_climatology(data; var = :tmean, period = (1981, 2010))            # per calendar month
monthly_means(data; var = :tmean)                                         # per (year, month)
```

## API

```@docs
daily_climatology
monthly_climatology
monthly_means
climate_day_comparison
climate_monthly
climate_daily
forecast_daily
set_offline!
offline_mode
```
