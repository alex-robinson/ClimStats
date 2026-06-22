# Hot days per year from ERA5, plus a bias-corrected CMIP6 projection to 2050.
#
# Pass the location as a string argument (defaults to Berlin):
#     julia --project=. -e 'import Pkg; Pkg.add("CairoMakie")'
#     julia --project=. examples/hot_days.jl "Paris, France"
# (needs internet access to reach the Open-Meteo APIs).

using ClimStats
using CairoMakie        # Makie backend for writing PNGs (use GLMakie for windows)
using Dates

place = isempty(ARGS) ? "Berlin, Germany" : ARGS[1]
slug  = strip(replace(lowercase(place), r"[^a-z0-9]+" => "_"), '_')
out(name) = joinpath(@__DIR__, "$(slug)_$(name).png")

# 1. The one-liner the package is built around.
fig = climate_timeseries(place; threshold = 30, start = Date(1950, 1, 1))
save(out("hot_days"), fig)
println("Saved figure -> ", out("hot_days"))

# 2. The same download reused for several indices.
data = era5_daily(place; start = Date(1950, 1, 1))
println(data)

for (name, idx) in [
        "Hot days (Tmax>30°C)"      => hot_days(data),
        "Summer days (Tmax>25°C)"   => summer_days(data),
        "Frost days (Tmin<0°C)"     => frost_days(data),
        "Tropical nights (Tmin>20)" => tropical_nights(data),
    ]
    tr = linear_trend(idx.year, idx.days)
    recent = last(idx.days, 10)
    @info name trend_per_decade = round(10 * tr.slope; digits = 2) recent_mean = round(sum(recent)/length(recent); digits = 1)
end

# 3. Mean-temperature warming signal.
warming = annual_mean(data; var = :tmean)
tr = linear_trend(warming.year, warming.mean)
println("Mean-temperature trend: ", round(10 * tr.slope; digits = 2), " °C / decade")

# 4. Past + future on one figure: ERA5 history plus a bias-corrected CMIP6
#    ensemble (median line + shaded spread), out to 2050.
proj = climate_projection(place; threshold = 30, hist_start = Date(1950, 1, 1))
save(out("hot_days_projection"), proj)
println("Saved projection figure -> ", out("hot_days_projection"))
