# Nowcasting the incomplete current year for hot days (Tmax > 30 °C).
#
# ERA5 stops a few days short of real time, so the current calendar year is
# always partial. Instead of plotting a misleading partial count, ClimStats
# completes the year from weighted analog years and shows a statistical estimate
# (lighter diamond + error bar).
#
# Pass the location as a string argument (defaults to Berlin):
#     julia --project=. -e 'import Pkg; Pkg.add("CairoMakie")'
#     julia --project=. examples/nowcast.jl "Paris, France"
# (needs internet access to reach the Open-Meteo APIs).

using ClimStats
using CairoMakie        # Makie backend for writing PNGs
using Dates

place = isempty(ARGS) ? "Berlin, Germany" : ARGS[1]
slug  = strip(replace(lowercase(place), r"[^a-z0-9]+" => "_"), '_')
out(name) = joinpath(@__DIR__, "$(slug)_$(name).png")

# Keep every panel on the same 1950–2050 x-range so the history-only and the
# history+projection figures line up.
function to_2050!(fig)
    ax = only(filter(c -> c isa Axis, fig.content))
    xlims!(ax, 1948, 2052)
    return fig
end

# 1. History + current-year estimate. `climate_timeseries` drops the partial
#    trailing year from the solid ERA5 line and overlays the nowcast estimate.
hist = climate_timeseries(place; threshold = 30, start = Date(1950, 1, 1))
to_2050!(hist)
save(out("nowcast"), hist)
println("Saved -> ", out("nowcast"))

# 2. History + current-year estimate + bias-corrected CMIP6 ensemble to 2050.
#    `nowcast = true` (the default) shows the same estimate on the combined view.
both = climate_projection(place; threshold = 30,
                          hist_start = Date(1950, 1, 1),
                          proj_stop = Date(2050, 12, 31))
to_2050!(both)
save(out("nowcast_projection"), both)
println("Saved -> ", out("nowcast_projection"))

# The estimate behind the markers can also be computed directly for any index:
#     data = era5_daily(place; start = Date(1950, 1, 1))
#     est  = estimate_current_year(data, d -> days_above(d, 30; var = :tmax); var = :tmax)
#     println(est)   # CurrentYearEstimate(2026: 5 [1–11], 165/365 days, 20 analogs)
