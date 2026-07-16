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
# or NEX-GDDP).
#
# The pool holds one *latest* copy of each rolling-history series (POWER / ERA5):
# because each monthly re-fetch returns the full span, the newest `through` is a
# superset of the older one, so collecting keeps the latest per cell and drops the
# now-redundant older prefix — the data we already have stays, and each refresh
# just extends it. Fixed archives (projections, geocode) are additive: new models
# or places accumulate, nothing is removed. The run is idempotent.

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
# Rolling-history cachetypes: re-fetched monthly as a growing full span, so only
# the latest `through` per cell is kept (see the dedup in `main`). Everything else
# in WANT is a fixed archive and every distinct instance is retained.
const HISTORY = Set(["climstats/power", "climstats/era5"])

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

    # Gather every cached instance that belongs to an example location.
    cell_of(cfg) = (get(cfg, "lat", NaN), get(cfg, "lon", NaN))
    candidates = Dict{String,Vector{NamedTuple}}()       # ctype => [(hash, path, cfg)]
    for (ctype, node) in get(state, "datacache", Dict{String,Any}())
        ctype in WANT || continue
        for (hash, path) in get(node, "instances", Dict{String,Any}())
            cfg_path = joinpath(path, "config.toml")
            isfile(cfg_path) || continue
            cfg = TOML.parsefile(cfg_path)
            keep = ctype == "climstats/geocode" ?
                (strip(get(cfg, "place", "")) in places) :
                (cell_of(cfg) in cells)
            keep || continue
            push!(get!(candidates, ctype, NamedTuple[]), (hash = hash, path = path, cfg = cfg))
        end
    end

    # A rolling-history series (POWER / ERA5) is re-fetched each month as the full
    # span `[start … last complete month]`, so a newer `through` is a *superset* of
    # the older one. Keep only the latest per cell — no observations are lost, and
    # the store doesn't grow a stale copy every month. Fixed archives (projections,
    # keyed by model; geocode, by place) are all kept, so new models just append.
    latest_hashes = Dict{String,Set{String}}()           # ctype => hashes to keep
    for (ctype, cs) in candidates
        if ctype in HISTORY
            best = Dict{Tuple{Float64,Float64},NamedTuple}()   # cell => newest candidate
            for c in cs
                cell = cell_of(c.cfg)
                if !haskey(best, cell) ||
                   get(c.cfg, "through", "") > get(best[cell].cfg, "through", "")
                    best[cell] = c
                end
            end
            latest_hashes[ctype] = Set(c.hash for c in values(best))
        else
            latest_hashes[ctype] = Set(c.hash for c in cs)
        end
    end

    # Copy the selected instances that aren't already in the pool.
    copied = 0; present = 0; pruned = 0
    for (ctype, cs) in candidates, c in cs
        c.hash in latest_hashes[ctype] || continue
        dest = joinpath(FIXTURES, ctype, c.hash)
        if isdir(dest)
            present += 1
        else
            mkpath(dirname(dest))
            cp(c.path, dest)
            copied += 1
            println("  + ", ctype, "/", first(c.hash, 8))
        end
    end

    # Drop any pool entry for a rolling-history cell that a newer `through` we just
    # kept now supersedes (older prefix; its data lives on in the newer superset).
    for (ctype, cs) in candidates
        ctype in HISTORY || continue
        kept_through = Dict{Tuple{Float64,Float64},String}()
        for c in cs
            c.hash in latest_hashes[ctype] || continue
            kept_through[cell_of(c.cfg)] = get(c.cfg, "through", "")
        end
        dir = joinpath(FIXTURES, ctype)
        isdir(dir) || continue
        for h in readdir(dir)
            h in latest_hashes[ctype] && continue
            cfg_path = joinpath(dir, h, "config.toml")
            isfile(cfg_path) || continue
            cell = cell_of(TOML.parsefile(cfg_path))
            through = get(TOML.parsefile(cfg_path), "through", "")
            (haskey(kept_through, cell) && through < kept_through[cell]) || continue
            rm(joinpath(dir, h); recursive = true)
            pruned += 1
            println("  - ", ctype, "/", first(h, 8), "  (superseded by ", kept_through[cell], ")")
        end
    end

    println("\nCopied $copied new, $present already present, $pruned superseded removed. Fixtures: $FIXTURES")
end

main()
