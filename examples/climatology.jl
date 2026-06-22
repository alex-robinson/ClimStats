# Climatological temperature figures for any location.
#
# Pass the location as a string argument (defaults to Berlin):
#     julia --project=. -e 'import Pkg; Pkg.add("CairoMakie")'
#     julia --project=. examples/climatology.jl "Paris, France"
# (needs internet access to reach the Open-Meteo APIs).
#
# To plot from cached data only — no network calls, live forecast omitted —
# set the offline flag (works for a location fetched online at least once):
#     CLIMSTATS_OFFLINE=1 julia --project=. examples/climatology.jl "Berlin, Germany"

using ClimStats
using CairoMakie        # Makie backend for writing PNGs (use GLMakie for windows)
using Dates

place = isempty(ARGS) ? "Berlin, Germany" : ARGS[1]
slug  = strip(replace(lowercase(place), r"[^a-z0-9]+" => "_"), '_')
out(name) = joinpath(@__DIR__, "$(slug)_$(name).png")

println("Building climatology figures for: ", place)

# 1. Today's forecast vs the day-of-year climatology across eras (bars):
#    black = today's forecast tmin–tmax, grey = 1981–2010 reference, blue =
#    2011–2025 observed, and 2041–2050 from a bias-corrected CMIP6 ensemble.
save(out("today_vs_climate"), climate_day_comparison(place))
println("  -> ", out("today_vs_climate"))

# 2. Monthly seasonal cycle: every year a faint grey line, last year and this
#    year highlighted, the 2041–2050 period as a shaded across-model band.
save(out("monthly_climatology"), climate_monthly(place))
println("  -> ", out("monthly_climatology"))

# 3. Daily seasonal cycle: the 1981–2010 95% interval as a light band, the
#    2041–2050 ensemble spread as a darker band, last year + this year on top,
#    and the live forecast (tmin–tmax band + mean). `spaghetti = true` overlays
#    every available year as a faint line.
save(out("daily_climatology"), climate_daily(place; spaghetti = true))
println("  -> ", out("daily_climatology"))
