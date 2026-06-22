# Current-year nowcast

ERA5 lags real time by about a week, so the **current calendar year is always
incomplete**. An index computed on it is misleading: a hot-day count or a
precipitation total is only a lower bound (the summer may not have happened yet),
and an annual mean is biased toward whichever season has elapsed.

Rather than plot that partial value, ClimStats *completes* the year from weighted
analog years and shows a statistical estimate with an uncertainty band — a
lighter diamond with a lo–hi error bar, distinct from the solid observed history.

## The two figures

The general script [`examples/nowcast.jl`](https://github.com/alex-robinson/ClimStats/blob/main/examples/nowcast.jl)
renders both figures below for any location (defaulting to Berlin). Run it from
the package root with a Makie backend and internet access:

```julia
julia --project=docs examples/nowcast.jl "Berlin, Germany"
```

### History + current-year estimate

`climate_timeseries` drops the trailing partial year from the solid ERA5 line and
overlays the nowcast estimate. The x-axis is fixed to 1950–2050 so it lines up
with the projection figure.

```julia
using ClimStats, CairoMakie, Dates

fig = climate_timeseries("Berlin, Germany"; threshold = 30,
                         start = Date(1950, 1, 1))   # nowcast = true by default
```

![Berlin hot days with current-year estimate](assets/berlin_hot_days_nowcast.png)

### History + estimate + CMIP6 projection

The same estimate appears on the combined past+future figure: ERA5 history, the
2026 nowcast, and a bias-corrected CMIP6 ensemble (median line + shaded spread)
out to 2050.

```julia
fig = climate_projection("Berlin, Germany"; threshold = 30,
                         hist_start = Date(1950, 1, 1),
                         proj_stop = Date(2050, 12, 31))
```

!!! note "Figure"
    Run [`examples/nowcast.jl`](https://github.com/alex-robinson/ClimStats/blob/main/examples/nowcast.jl)
    to render this combined past+future figure (it needs live Open-Meteo access
    for the CMIP6 ensemble, so it is not embedded here).

Pass `nowcast = false` to either helper to fall back to the raw partial value.

## How the estimate is built

Analog resampling, in [`src/nowcast.jl`](https://github.com/alex-robinson/ClimStats/blob/main/src/nowcast.jl):

1. **Similarity** — compare the current year's observed window (Jan 1 → last
   available day) against the *same calendar window* of every complete prior
   year, by RMSE of the daily similarity variable. Closer years are better
   analogs.
2. **Weights** — turn those distances into weights with a Gaussian kernel,
   optionally keeping only the top-K analogs.
3. **Anchored trajectories** — for each analog year, take its remaining days as a
   candidate trajectory for the rest of *this* year, shifted so its window mean
   matches the current year's (additive for temperatures, multiplicative for
   precipitation). This tracks how the year is actually running and preserves the
   day-to-day structure within an analog.
4. **Index distribution** — each anchored analog yields a *completed* daily
   series; running an index over the weighted members gives the median and lo–hi
   band that are plotted.

The uncertainty therefore lives at the index level (derived from the ensemble),
while daily provenance lives in the data: each completed member carries a Boolean
`:estimated` column (`false` for observed days, `true` for analog-filled days), so
the synthetic tail never silently mixes with observations.

## Calling the estimator directly

```julia
data = era5_daily("Berlin, Germany"; start = Date(1950, 1, 1))

est = estimate_current_year(data, d -> days_above(d, 30; var = :tmax); var = :tmax)
# CurrentYearEstimate(2026: 5 [1–11], 165/365 days, 20 analogs)  (illustrative)

est.median, est.lo, est.hi      # the estimate and its band
est.observed_partial            # the (lower-bound) count from observed days only

members = complete_current_year(data; var = :tmax)   # the completed daily series
members[1].table.estimated                            # false for observed, true for filled
```

## API

```@docs
estimate_current_year
complete_current_year
CurrentYearEstimate
incomplete_final_year
plot_nowcast!
```
