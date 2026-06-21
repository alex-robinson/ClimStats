"""
    ClimStats

An API for retrieving and analysing climate data for a single location, from
ERA5 reanalysis (the past) and CMIP6 climate projections (the future).

Quick start
-----------
```julia
using ClimStats
using CairoMakie            # a Makie backend: CairoMakie for files, GLMakie for windows

# One-liner: location string in, figure out.
fig = climate_timeseries("Berlin, Germany"; threshold = 30)
save("berlin_hot_days.png", fig)   # `save` re-exported from Makie

# Or step by step, to compute many things from the same download.
data   = era5_daily("Berlin, Germany")     # daily tmax/tmin/tmean/precip
hot    = days_above(data, 30)              # days/yr with Tmax > 30 °C
frost  = frost_days(data)                  # days/yr with Tmin < 0 °C
warming = annual_mean(data; var = :tmean)  # yearly mean temperature
plot_index(hot)
```

ERA5 history and the Open-Meteo CMIP6 ensemble are fetched live from the free,
key-less Open-Meteo APIs (internet required). SSP-scenario projections use the
NASA NEX-GDDP-CMIP6 backend (`nexgddp_daily`, `ssp_ensemble`, `climate_ssp`),
enabled by `using NCDatasets`. Plots are built with Makie (core); load a backend
(`CairoMakie` to save files, `GLMakie`/`WGLMakie` for interactive use) to render
or `save` the returned `Figure`. See also `era5_daily`, the index helpers
(`days_above`, `frost_days`, `annual_mean`, …), `bias_correct` and `plot_index`.
"""
module ClimStats

using Dates
using Printf
using Statistics
using DataFrames
using HTTP
using JSON3
using Makie

export Location, ClimateData, geocode, table, variables
export era5_daily, projection_daily, default_stop, PROJECTION_MODELS
export annual_count, days_above, days_below, annual_mean, annual_sum, linear_trend
export hot_days, summer_days, frost_days, icing_days, tropical_nights, wet_days
export BiasCorrection, QuantileCorrection, AbstractBiasCorrection
export fit_bias_correction, apply_bias_correction, bias_correct, DEFAULT_REF
export Ensemble, projection_ensemble, ensemble_summary, ensemble_index
export CurrentYearEstimate, incomplete_final_year, complete_current_year, estimate_current_year
export plot_index, plot_index!, plot_ensemble!, plot_nowcast!, climate_timeseries, climate_projection
export save  # re-exported from Makie; load a backend (CairoMakie/GLMakie) to render
export SSP_SCENARIOS, NEXGDDP_MODELS, NEXGDDP_DEFAULT_MODELS, nexgddp_model_spec
export scenario_label, nexgddp_daily, ssp_ensemble, climate_ssp

include("types.jl")
include("cache.jl")
include("providers.jl")
include("indices.jl")
include("bias.jl")
include("ensemble.jl")
include("nowcast.jl")
include("plotting.jl")
include("nexgddp.jl")

end # module ClimStats
