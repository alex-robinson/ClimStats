# Headline example: hot days per year in Berlin from ERA5.
#
# Run from the package root with:
#     julia --project=. examples/berlin.jl
# (needs internet access to reach the Open-Meteo APIs).

using ClimStats
using Dates

# 1. The one-liner the package is built around.
fig = climate_timeseries("Berlin, Germany"; threshold = 30,
                         start = Date(1950, 1, 1))
save(joinpath(@__DIR__, "berlin_hot_days.png"), fig)
println("Saved figure -> ", joinpath(@__DIR__, "berlin_hot_days.png"))

# 2. The same download reused for several indices.
data = era5_daily("Berlin, Germany"; start = Date(1950, 1, 1))
println(data)

for (name, idx) in [
        "Hot days (Tmax>30°C)"      => hot_days(data),
        "Summer days (Tmax>25°C)"   => summer_days(data),
        "Frost days (Tmin<0°C)"     => frost_days(data),
        "Tropical nights (Tmin>20)" => tropical_nights(data),
    ]
    tr = linear_trend(idx.year, idx.days)
    recent = last(idx.days, min(10, nrow(idx)))
    @info name trend_per_decade = round(10 * tr.slope; digits = 2) recent_mean = round(sum(recent)/length(recent); digits = 1)
end

# 3. Mean-temperature warming signal.
warming = annual_mean(data; var = :tmean)
tr = linear_trend(warming.year, warming.mean)
println("Mean-temperature trend: ", round(10 * tr.slope; digits = 2), " °C / decade")

# 4. Past + future on one figure: ERA5 history plus a bias-corrected CMIP6
#    ensemble (median line + shaded spread), out to 2050.
proj = climate_projection("Berlin, Germany"; threshold = 30,
                          hist_start = Date(1950, 1, 1))
save(joinpath(@__DIR__, "berlin_hot_days_projection.png"), proj)
println("Saved projection figure -> ",
        joinpath(@__DIR__, "berlin_hot_days_projection.png"))
