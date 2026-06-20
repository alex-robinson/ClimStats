# Nowcasting the incomplete current year, for Berlin hot days (Tmax > 30 °C).
#
# ERA5 stops a few days short of real time, so the current calendar year is
# always partial. Instead of plotting a misleading partial count, ClimStats
# completes the year from weighted analog years and shows a statistical estimate
# (lighter diamond + error bar). This script renders the two figures used in the
# documentation page. Needs a Makie backend and internet access:
#     julia --project=docs examples/berlin_nowcast.jl

using ClimStats
using CairoMakie        # Makie backend for writing PNGs
using Dates

const ASSETS = joinpath(@__DIR__, "..", "docs", "src", "assets")
mkpath(ASSETS)

# Keep every panel on the same 1950–2050 x-range so the history-only and the
# history+projection figures line up.
function to_2050!(fig)
    ax = only(filter(c -> c isa Axis, fig.content))
    xlims!(ax, 1948, 2052)
    return fig
end

# 1. History + current-year estimate. `climate_timeseries` drops the partial
#    trailing year from the solid ERA5 line and overlays the nowcast estimate.
hist = climate_timeseries("Berlin, Germany"; threshold = 30,
                          start = Date(1950, 1, 1))
to_2050!(hist)
save(joinpath(ASSETS, "berlin_hot_days_nowcast.png"), hist)
println("Saved -> ", joinpath(ASSETS, "berlin_hot_days_nowcast.png"))

# 2. History + current-year estimate + bias-corrected CMIP6 ensemble to 2050.
#    `nowcast = true` (the default) shows the same estimate on the combined view.
both = climate_projection("Berlin, Germany"; threshold = 30,
                          hist_start = Date(1950, 1, 1),
                          proj_stop = Date(2050, 12, 31))
to_2050!(both)
save(joinpath(ASSETS, "berlin_hot_days_projection_nowcast.png"), both)
println("Saved -> ", joinpath(ASSETS, "berlin_hot_days_projection_nowcast.png"))

# The estimate behind the markers can also be computed directly for any index:
#     data = era5_daily("Berlin, Germany"; start = Date(1950, 1, 1))
#     est  = estimate_current_year(data, d -> days_above(d, 30; var = :tmax); var = :tmax)
#     println(est)   # CurrentYearEstimate(2026: 5 [1–11], 165/365 days, 20 analogs)
