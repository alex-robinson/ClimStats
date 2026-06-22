# Fetch the point-series used by the example locations, so they can be bundled as
# committed offline fixtures (see scripts/collect_fixtures.jl, which copies the
# results into data/fixtures — the runtime read pool).
#
#   julia --project=. scripts/generate_fixtures.jl
#
# Network is required. Series are content-addressed and cached, so the run is
# idempotent and resumable: already-fetched series are reused, and each fetch is
# guarded so an Open-Meteo quota error (429) skips just that item and continues —
# NASA POWER (keyless, no quota) and any already-cached projections still land.
# Rerun after the hourly quota resets to fill in the projections that were skipped.

using ClimStats
using Dates

const LOCATIONS = [
    "Berlin, Germany",
    "Madrid, Spain",
    "Athens, Greece",
    "Fort Collins, Colorado",
]

# Run `f()`, returning true on success; on an Open-Meteo quota error (or any
# other failure) print a short note and return false instead of throwing.
function try_fetch(label, f)
    try
        f()
        println("    ok    ", label)
        return true
    catch err
        msg = sprint(showerror, err)
        short = occursin("429", msg) || occursin(r"limit"i, msg) ? "quota" : "fail"
        println("    ", short, "  ", label, "  (", first(split(msg, '\n')), ")")
        return false
    end
end

for place in LOCATIONS
    println("\n=== ", place, " ===")
    loc = nothing
    try
        loc = geocode(place)
        println("    ok    geocode -> ", loc.name, ", ", loc.country)
    catch err
        println("    fail  geocode (", first(split(sprint(showerror, err), '\n')), ")")
        continue                      # cannot proceed without coordinates
    end

    try_fetch("POWER history", () -> power_daily(loc))          # keyless, no quota
    try_fetch("ERA5 history",  () -> era5_daily(loc))           # Open-Meteo (quota)

    for m in PROJECTION_MODELS                                   # Open-Meteo (quota)
        try_fetch("projection $m", () -> projection_daily(loc; model = m))
    end
end

println("\nDone. Run scripts/collect_fixtures.jl to copy results into data/fixtures.")
