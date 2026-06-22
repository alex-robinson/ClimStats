# SSP-scenario projections via NASA NEX-GDDP-CMIP6.
#
# Pass the location as a string argument (defaults to Berlin):
#     julia --project=. -e 'import Pkg; Pkg.add(["CairoMakie", "NCDatasets"])'
#     julia --project=. examples/ssp.jl "Paris, France"
#
# NEX-GDDP fans out into one OPeNDAP read per model/scenario/variable/year, so
# this can take a while; it is kept small (few models, one variable) by default.

using ClimStats
using CairoMakie        # Makie backend for writing the figure
using NCDatasets        # loads the NEX-GDDP backend (package extension)
using Dates

place = isempty(ARGS) ? "Berlin, Germany" : ARGS[1]
slug  = strip(replace(lowercase(place), r"[^a-z0-9]+" => "_"), '_')
out(name) = joinpath(@__DIR__, "$(slug)_$(name).png")

# 1. A single model + scenario, historical and SSP spliced into one daily series.
data = nexgddp_daily(place;
                     model = "MPI-ESM1-2-HR", scenario = :ssp585,
                     start = Date(1990, 1, 1), stop = Date(2100, 12, 31),
                     vars = (:tmax,))
println(data)
println("Hot days (Tmax>30°C), last decade of the century:")
show(stdout, MIME"text/plain"(), last(days_above(data, 30), 10))
println()

# 2. The headline SSP figure: ERA5 history + a bias-corrected NEX-GDDP ensemble
#    for three scenarios, each a median line with a shaded spread band, to 2100.
fig = climate_ssp(place; threshold = 30,
                  scenarios = (:ssp126, :ssp245, :ssp585),
                  models = NEXGDDP_DEFAULT_MODELS)
save(out("hot_days_ssp"), fig)
println("Saved SSP figure -> ", out("hot_days_ssp"))
