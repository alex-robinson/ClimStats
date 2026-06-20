"""
    ClimStats

An API for retrieving and analysing climate data for a single location, from
ERA5 reanalysis (the past) and CMIP6 climate projections (the future).

Quick start
-----------
```julia
using ClimStats

# One-liner: location string in, figure out.
plt = climate_timeseries("Berlin, Germany"; threshold = 30)
savefig(plt, "berlin_hot_days.png")

# Or step by step, to compute many things from the same download.
data   = era5_daily("Berlin, Germany")     # daily tmax/tmin/tmean/precip
hot    = days_above(data, 30)              # days/yr with Tmax > 30 °C
frost  = frost_days(data)                  # days/yr with Tmin < 0 °C
warming = annual_mean(data; var = :tmean)  # yearly mean temperature
plot_index(hot)
```

Data are fetched live from the free, key-less Open-Meteo APIs, so an internet
connection is required. See `era5_daily`, `projection_daily`, the index helpers
(`days_above`, `frost_days`, `annual_mean`, …) and `plot_index`.
"""
module ClimStats

using Dates
using Printf
using Statistics
using DataFrames
using HTTP
using JSON3
using Plots

export Location, ClimateData, geocode, table, variables
export era5_daily, projection_daily, default_stop, PROJECTION_MODELS
export annual_count, days_above, days_below, annual_mean, annual_sum, linear_trend
export hot_days, summer_days, frost_days, icing_days, tropical_nights, wet_days
export BiasCorrection, QuantileCorrection, AbstractBiasCorrection
export fit_bias_correction, apply_bias_correction, bias_correct, DEFAULT_REF
export Ensemble, projection_ensemble, ensemble_summary, ensemble_index
export plot_index, plot_index!, plot_ensemble!, climate_timeseries, climate_projection

include("types.jl")
include("providers.jl")
include("indices.jl")
include("bias.jl")
include("ensemble.jl")
include("plotting.jl")

end # module ClimStats
