# ClimStats

A Julia package that provides an API for retrieving climate data for a single
location and calculating things from it — starting with **ERA5 reanalysis** (the
past) and growing toward **CMIP6 climate projections** (the future).

The headline goal: write a place name like `"Berlin, Germany"` and get back the
data *and* a figure — e.g. a time series of the number of days per year above
30 °C.

```julia
using ClimStats

plt = climate_timeseries("Berlin, Germany"; threshold = 30)
savefig(plt, "berlin_hot_days.png")
```

![example](examples/berlin_hot_days.png)

## Installation

```julia
using Pkg
Pkg.develop(path = ".")   # from a clone of this repo
# or, once it lives on GitHub:
# Pkg.add(url = "https://github.com/alex-robinson/climstats")
```

Then `instantiate` to pull the dependencies (DataFrames, HTTP, JSON3, Plots):

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

## Projections (next step)

The groundwork is already in place. `projection_daily` pulls CMIP6 daily data
(1950–2050) with the *same* return type as `era5_daily`, so the same indices and
plots apply. You can already overlay history and a projection:

```julia
hist = era5_daily("Berlin, Germany")
proj = projection_daily("Berlin, Germany"; model = "MRI_AGCM3_2_S")

plt = plot_index(days_above(hist, 30); label = "ERA5")
plot_index!(plt, days_above(proj, 30); label = "MRI_AGCM3_2_S")
```

Planned refinements for the projections step: multi-model ensembles with spread,
bias-adjustment against the ERA5 baseline, and scenario (SSP) selection. See
`PROJECTION_MODELS` for the models currently available.

## Project layout

```
src/
  ClimStats.jl   # module, exports, includes
  types.jl       # Location, ClimateData
  providers.jl   # geocode + era5_daily + projection_daily (Open-Meteo)
  indices.jl     # days_above/below, annual_mean/sum, named indices, trend
  plotting.jl    # plot_index, plot_index!, climate_timeseries
examples/
  berlin.jl      # the headline example end-to-end
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

Early days (`v0.1`). The ERA5 retrieval + indices + plotting path is complete;
projections are scaffolded and are the next milestone.
