# SSP-scenario projections for Berlin via NASA NEX-GDDP-CMIP6.
#
# Needs a Makie backend, the NetCDF stack, and internet access to NASA NCCS:
#     julia --project=. -e 'import Pkg; Pkg.add(["CairoMakie", "NCDatasets"])'
#     julia --project=. examples/berlin_ssp.jl
#
# NEX-GDDP fans out into one OPeNDAP read per model/scenario/variable/year, so
# this can take a while; it is kept small (few models, one variable) by default.

using ClimStats
using CairoMakie        # Makie backend for writing the figure
using NCDatasets        # loads the NEX-GDDP backend (package extension)
using Dates

# 1. A single model + scenario, historical and SSP spliced into one daily series.
data = nexgddp_daily("Berlin, Germany";
                     model = "MPI-ESM1-2-HR", scenario = :ssp585,
                     start = Date(1990, 1, 1), stop = Date(2100, 12, 31),
                     vars = (:tmax,))
println(data)
println("Hot days (Tmax>30°C), last decade of the century:")
show(stdout, MIME"text/plain"(), last(days_above(data, 30), 10))
println()

# 2. The headline SSP figure: ERA5 history + a bias-corrected NEX-GDDP ensemble
#    for three scenarios, each a median line with a shaded spread band, to 2100.
fig = climate_ssp("Berlin, Germany"; threshold = 30,
                  scenarios = (:ssp126, :ssp245, :ssp585),
                  models = NEXGDDP_DEFAULT_MODELS)
save(joinpath(@__DIR__, "berlin_hot_days_ssp.png"), fig)
println("Saved SSP figure -> ", joinpath(@__DIR__, "berlin_hot_days_ssp.png"))
