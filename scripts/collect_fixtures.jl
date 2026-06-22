# Copy the cached point-series for the example locations into data/fixtures, the
# directory ClimStats registers as a DataManifest read pool at load time (see
# `_register_fixture_pool`). Run after scripts/generate_fixtures.jl.
#
#   julia --project=. scripts/collect_fixtures.jl
#
# Sources are located via DataManifest's own state index (`.datamanifest/
# state.toml`), so wherever a series was cached, it is found. Only entries for the
# example locations are copied — geocode keyed by place string, the rest by their
# snapped grid cell — and only the offline-relevant cachetypes (no bias-correction
# or NEX-GDDP). Already-present fixtures are left untouched.

using ClimStats
using ClimStats: _snap, _snap_power_lat, _snap_power_lon
import TOML

const ROOT     = normpath(joinpath(@__DIR__, ".."))
const FIXTURES = joinpath(ROOT, "data", "fixtures")
const STATE    = joinpath(ROOT, ".datamanifest", "state.toml")

const LOCATIONS = [
    "Berlin, Germany",
    "Madrid, Spain",
    "Athens, Greece",
    "Fort Collins, Colorado",
]
# Cachetypes worth bundling: location-stable history + projections. Deliberately
# excludes derived bias-correction caches and the heavy NEX-GDDP series.
const WANT = Set([
    "climstats/geocode", "climstats/power", "climstats/era5", "climstats/projection",
])

function main()
    # Acceptable identities for the example locations: the geocode place strings,
    # and the snapped (lat, lon) cells on both the 0.25° (ERA5/CMIP6) and ~0.5°
    # (POWER) grids.
    places = Set{String}()
    cells  = Set{Tuple{Float64,Float64}}()
    for place in LOCATIONS
        push!(places, strip(place))
        loc = geocode(place)                               # cached after generate
        push!(cells, (_snap(loc.latitude), _snap(loc.longitude)))
        push!(cells, (_snap_power_lat(loc.latitude), _snap_power_lon(loc.longitude)))
    end

    isfile(STATE) ||
        error("No DataManifest state at $STATE — run generate_fixtures.jl first.")
    state = TOML.parsefile(STATE)
    mkpath(FIXTURES)

    copied = 0; present = 0
    for (ctype, node) in get(state, "datacache", Dict{String,Any}())
        ctype in WANT || continue
        for (hash, path) in get(node, "instances", Dict{String,Any}())
            cfg_path = joinpath(path, "config.toml")
            isfile(cfg_path) || continue
            cfg = TOML.parsefile(cfg_path)
            keep = ctype == "climstats/geocode" ?
                (strip(get(cfg, "place", "")) in places) :
                ((get(cfg, "lat", NaN), get(cfg, "lon", NaN)) in cells)
            keep || continue
            dest = joinpath(FIXTURES, ctype, hash)
            if isdir(dest)
                present += 1
            else
                mkpath(dirname(dest))
                cp(path, dest)
                copied += 1
                println("  + ", ctype, "/", first(hash, 8))
            end
        end
    end

    println("\nCopied $copied new, $present already present. Fixtures: $FIXTURES")
end

main()
