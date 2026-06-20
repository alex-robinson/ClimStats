# ClimStats

A Julia package that provides an API for retrieving climate data for a single
location and calculating things from it — starting with **ERA5 reanalysis** (the
past) and growing toward **CMIP6 climate projections** (the future).

The headline goal: write a place name like `"Berlin, Germany"` and get back the
data *and* a figure — e.g. a time series of the number of days per year above
30 °C.

```julia
using ClimStats

fig = climate_timeseries("Berlin, Germany"; threshold = 30)
save("berlin_hot_days.png", fig)        # `save` is re-exported from CairoMakie
```

![example](examples/berlin_hot_days.png)

Figures are built with [Makie](https://docs.makie.org) via the CairoMakie
backend. `using ClimStats` activates it and re-exports `save`, so the line above
works as-is; load `GLMakie` yourself if you want interactive windows instead.

## Installation

```julia
using Pkg
Pkg.develop(path = ".")   # from a clone of this repo
# or, once it lives on GitHub:
# Pkg.add(url = "https://github.com/alex-robinson/climstats")
```

Then `instantiate` to pull the dependencies (DataFrames, HTTP, JSON3, CairoMakie):

```julia
Pkg.activate(".")
Pkg.instantiate()
```

## Quick start

The package is designed so that one download lets you compute many things.

```julia
using ClimStats, Dates

# Resolve a place to coordinates.
loc = geocode("Berlin, Germany")          # Location(Berlin, Germany @ 52.52°N, 13.41°E)

# Download daily ERA5 (tmax / tmin / tmean / precip) for that point.
data = era5_daily(loc; start = Date(1950,1,1))

# Compute indices — each returns a tidy DataFrame of one value per year.
hot     = days_above(data, 30)            # days/yr with Tmax > 30 °C
frost   = frost_days(data)                # days/yr with Tmin < 0 °C
tropics = tropical_nights(data)           # days/yr with Tmin > 20 °C
warming = annual_mean(data; var = :tmean) # yearly mean temperature
rainfall = annual_sum(data; var = :precip)# yearly total precipitation

# Plot any of them (a dashed least-squares trend line is added automatically).
plot_index(hot; ylabel = "days per year",
           title = "Hot days in Berlin (ERA5)")
```

### The variables you get

`era5_daily` returns a `ClimateData` whose `.table` is a daily `DataFrame` with:

| column   | meaning                          | units |
|----------|----------------------------------|-------|
| `:date`  | calendar day                     | `Date`|
| `:tmax`  | daily maximum 2 m temperature    | °C    |
| `:tmin`  | daily minimum 2 m temperature    | °C    |
| `:tmean` | daily mean 2 m temperature       | °C    |
| `:precip`| daily total precipitation        | mm    |

That's enough to build a great many indices. Provided out of the box:

- `days_above(data, T; var)` / `days_below(data, T; var)` — generic day counts
- `annual_count(data, predicate; var)` — count days matching any predicate
- `annual_mean(data; var)` / `annual_sum(data; var)` — continuous annual stats
- Named ETCCDI-style helpers: `hot_days`, `summer_days`, `frost_days`,
  `icing_days`, `tropical_nights`, `wet_days`
- `linear_trend(years, values)` — OLS slope/intercept for any series

## How it works (data sources)

This first version uses the free, **no-API-key** [Open-Meteo](https://open-meteo.com)
HTTP APIs, which serve point time series directly (no need to download and crop
gridded files):

| Need                | Endpoint                            | Product            |
|---------------------|-------------------------------------|--------------------|
| place → coordinates | `geocoding-api.open-meteo.com`      | —                  |
| past (ERA5)         | `archive-api.open-meteo.com`        | ERA5 / ERA5-Land   |
| future (CMIP6)      | `climate-api.open-meteo.com`        | CMIP6 (downscaled) |

> **Network access is required at runtime.** Data are fetched live.

### Why not the Copernicus CDS directly?

Native ERA5 from the Copernicus Climate Data Store requires an account, an API
key, accepting a licence, and downloading large gridded NetCDF/GRIB files that
you then crop to a point. For "give me one location's daily series" that is a lot
of overhead. ClimStats therefore starts with Open-Meteo's ERA5 archive, but the
provider layer is deliberately thin and isolated (`src/providers.jl`): a future
CDS-backed downloader only has to return a `ClimateData` using the same column
convention, and every index/plot helper keeps working unchanged.

## Projections: past + future on one figure

The projections step is implemented. `climate_projection` geocodes the place,
downloads ERA5 history *and* a multi-model CMIP6 ensemble (to 2050),
bias-corrects each model against the ERA5 baseline, and draws the index for both
on one set of axes — the ensemble as a median line with a shaded spread band:

```julia
fig = climate_projection("Berlin, Germany"; threshold = 30)
save("berlin_hot_days_projection.png", fig)
```

![projection](examples/berlin_hot_days_projection.png)

It composes from three reusable pieces, so you can drive each stage yourself:

```julia
hist = era5_daily("Berlin, Germany")

# 1. Multi-model ensemble (one member per model, failures skipped with a warning).
ens = projection_ensemble("Berlin, Germany")          # -> Ensemble

# 2. Bias-correct every member against the ERA5 baseline (1991–2020 by default).
ens = bias_correct(ens, hist)                         # per-month delta correction

# 3. Summarise the spread of any index across the ensemble.
summary = ensemble_index(ens, d -> days_above(d, 30)) # year, lo, median, hi, mean, n

fig = plot_index(days_above(hist, 30); label = "ERA5", trend = false)
plot_ensemble!(fig, summary; label = "CMIP6 (bias-corr.)")
```

Any index works in `climate_projection` via the `index` keyword, e.g. mean
warming instead of hot-day counts:

```julia
climate_projection("Berlin, Germany"; index = d -> annual_mean(d; var = :tmean))
```

### How the bias correction works

Models carry systematic biases relative to reanalysis, so raw model values can't
feed absolute-threshold indices directly. ClimStats corrects each model towards
ERA5 over a reference period (default the 1991–2020 WMO normal), per calendar
month, with a choice of method (`fit_bias_correction` / `apply_bias_correction` /
`bias_correct`, or the `method` keyword to `climate_projection`):

| `method`  | what it does                                                        |
|-----------|---------------------------------------------------------------------|
| `:qdm`    | **Quantile Delta Mapping** (default) — matches the whole distribution to ERA5 *and* preserves the model's projected change at each quantile (Cannon et al. 2015). Best for projections. |
| `:eqm`    | Empirical Quantile Mapping — matches the distribution to ERA5 by CDF. |
| `:delta`  | Per-month mean shift only — fast, corrects the mean but not the distribution shape. |

All methods are **additive** for temperatures and **multiplicative** for
precipitation. Quantile mapping corrects not just the mean but the variance and
tails, which is what makes threshold indices (days > 30 °C, frost days, …)
trustworthy on model data.

```julia
bias_correct(model, hist; method = :qdm)   # or :eqm, :delta
climate_projection("Berlin, Germany"; method = :qdm)
```

## SSP scenarios (NEX-GDDP-CMIP6)

Open-Meteo's CMIP6 ensemble follows a single fixed pathway, so for
scenario-aware projections ClimStats adds a **NASA NEX-GDDP-CMIP6** backend:
daily, statistically downscaled (0.25°) CMIP6 covering historical (1950–2014)
and the four SSPs — `:ssp126`, `:ssp245`, `:ssp370`, `:ssp585` — to 2100.

It reads point time series over OPeNDAP, so it needs the NetCDF stack. That is
an **optional dependency**, enabled via a package extension — just load it:

```julia
using ClimStats
using NCDatasets        # enables the NEX-GDDP backend

# One model, one scenario (historical + SSP spliced into one daily series):
data = nexgddp_daily("Berlin, Germany"; model = "MPI-ESM1-2-HR", scenario = :ssp585)

# The headline SSP figure: ERA5 history + a bias-corrected ensemble per scenario.
fig = climate_ssp("Berlin, Germany"; threshold = 30,
                  scenarios = (:ssp126, :ssp245, :ssp585))
save("berlin_hot_days_ssp.png", fig)
```

`nexgddp_daily` returns the same [`ClimateData`](#) shape as `era5_daily`, so
indices, quantile-mapping bias correction and plotting all apply. `ssp_ensemble`
builds a multi-model `Ensemble` for one scenario; `climate_ssp` overlays one
shaded fan per SSP.

> **Download cost.** NEX-GDDP stores one file per model/scenario/variable/year,
> so requests fan out into many OPeNDAP reads. `climate_ssp` therefore defaults
> to a small model set (`NEXGDDP_DEFAULT_MODELS`) and fetches only the variable
> the index needs. Widen `models`, `vars` and the year range as needed.
>
> Model realisation/grid labels vary; the registry (`nexgddp_model_spec`) covers
> common cases and falls back to `r1i1p1f1`/`gn`. Override per call with
> `variant`/`grid` if a model uses something else (unavailable files are skipped
> with a warning rather than aborting the ensemble).

## Project layout

```
src/
  ClimStats.jl   # module, exports, includes
  types.jl       # Location, ClimateData
  providers.jl   # geocode + era5_daily + projection_daily (Open-Meteo)
  indices.jl     # days_above/below, annual_mean/sum, named indices, trend
  bias.jl        # bias correction (delta + quantile mapping) vs ERA5
  ensemble.jl    # multi-model ensembles + spread summaries
  plotting.jl    # plot_index, plot_ensemble!, climate_timeseries/projection
  nexgddp.jl     # NEX-GDDP-CMIP6 / SSP logic + climate_ssp (pure parts)
ext/
  ClimStatsNCDatasetsExt.jl  # NetCDF/OPeNDAP reads (loaded by `using NCDatasets`)
examples/
  berlin.jl      # the headline ERA5 example end-to-end
  berlin_ssp.jl  # SSP scenarios via NEX-GDDP-CMIP6
test/
  runtests.jl    # offline unit tests (+ optional live tests)
```

## Tests

The unit tests run **offline** (they exercise the index, parsing and plotting
logic on synthetic data):

```julia
using Pkg; Pkg.test()
```

To additionally run the live Open-Meteo tests:

```bash
CLIMSTATS_NETWORK_TESTS=true julia --project=. -e 'using Pkg; Pkg.test()'
```

## Status

Early days (`v0.1`). Complete: ERA5 retrieval, indices, plotting, multi-model
CMIP6 ensembles, combined past+future figures, bias adjustment against ERA5
(delta-change *and* quantile-mapping QDM/EQM), and SSP-scenario projections via
the NEX-GDDP-CMIP6 backend (`climate_ssp`). The live NEX-GDDP path is
implemented against NASA NCCS OPeNDAP but, unlike the offline-tested core, has
not yet been exercised end-to-end here — try it and report back.
