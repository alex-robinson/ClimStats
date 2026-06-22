# Render the climatology figures for each documented example location into
# docs/src/assets, drawing only on cached / bundled data (offline) so the build
# is deterministic and quota-free. A location whose CMIP6 ensemble is only
# partially cached is rendered with the models on hand; one with none is skipped
# (its page notes the figures are pending). To refresh the data first, run
# scripts/generate_fixtures.jl + scripts/collect_fixtures.jl.
#
#     julia --project=docs docs/make_city_figures.jl
#
# An asset that already exists is kept (delete it to force a re-render), so the
# Berlin figures committed earlier — which include the live-forecast bar — are
# preserved.

ENV["CLIMSTATS_OFFLINE"] = "1"
using ClimStats
using CairoMakie

const CITIES = [
    ("Berlin, Germany",        "berlin_germany"),
    ("Madrid, Spain",          "madrid_spain"),
    ("Athens, Greece",         "athens_greece"),
    ("Fort Collins, Colorado", "fort_collins_colorado"),
]
const ASSETS = joinpath(@__DIR__, "src", "assets")
mkpath(ASSETS)

# Projection models with a cached series for `place` (probed offline; an uncached
# model throws and is skipped).
function cached_models(place)
    ms = String[]
    for m in PROJECTION_MODELS
        try
            projection_daily(place; model = m)
            push!(ms, m)
        catch
        end
    end
    return ms
end

const SUMMARY = Tuple{String,String,Vector{String}}[]

for (place, slug) in CITIES
    println("=== ", place, " ===")
    models = cached_models(place)
    println("  cached projection models: ", isempty(models) ? "(none)" : join(models, ", "))
    made = String[]
    if !isempty(models)
        figs = [
            ("today_vs_climate",    () -> climate_day_comparison(place; models = models)),
            ("monthly_climatology", () -> climate_monthly(place; models = models)),
            ("daily_climatology",   () -> climate_daily(place; models = models, spaghetti = true)),
        ]
        for (name, build) in figs
            path = joinpath(ASSETS, "$(slug)_$(name).png")
            if isfile(path)
                println("  kept ", name, " (already present)")
                push!(made, name)
                continue
            end
            try
                save(path, build())
                println("  ok   ", name)
                push!(made, name)
            catch err
                println("  skip ", name, "  (", first(split(sprint(showerror, err), '\n')), ")")
            end
        end
    else
        println("  no projection ensemble cached yet — figures skipped")
    end
    push!(SUMMARY, (place, slug, made))
end

println("\nSummary:")
for (place, _, made) in SUMMARY
    println("  ", rpad(place, 26), " -> ", isempty(made) ? "(no figures)" : join(made, ", "))
end
