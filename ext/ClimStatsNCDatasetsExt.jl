module ClimStatsNCDatasetsExt

# NetCDF/OPeNDAP reading for the NEX-GDDP-CMIP6 backend. Loaded automatically
# when the user does `using NCDatasets`. Everything pure (URLs, scenarios, unit
# conversion, the model registry) lives in ClimStats itself; this extension only
# adds the methods that actually open remote NetCDF files.
#
# Reads are cached like ERA5 (see src/cache.jl): the archive is fixed, so we
# fetch the full 1950–2100 span once per (model, scenario, variant, grid,
# variable, grid-cell), store it as Arrow, and serve any requested date range
# from it. That turns the ~150 OPeNDAP file reads of a cold fetch into a one-time
# cost per cell.

using ClimStats
using ClimStats: Location, ClimateData, geocode,
    NEXGDDP_BASE, NEXGDDP_VARMAP, nexgddp_model_spec, _normalize_scenario,
    _scenario_for_year, _nexgddp_url, NEXGDDP_START, NEXGDDP_STOP,
    _snap, _arrow_save, _arrow_load
using DataManifest: @cached
using NCDatasets
using DataFrames
using Dates

# Read one grid-cell, one-year time series from a single NEX-GDDP file.
# Returns (dates, values) in native units. Subsetting happens lazily over
# OPeNDAP, so only the cell is transferred, not the global field.
function _read_point_year(url, nexvar, lat, lon)
    return NCDataset(url) do ds
        lats = ds["lat"][:]
        lons = ds["lon"][:]
        ilat = argmin(abs.(lats .- lat))
        ilon = argmin(abs.(lons .- mod(lon, 360)))     # NEX-GDDP lon is 0–360
        v = ds[nexvar]
        # Index by dimension name so we are robust to the stored axis order.
        idx = Tuple(d == "lon" ? ilon : d == "lat" ? ilat : Colon()
                    for d in NCDatasets.dimnames(v))
        raw = Array(v[idx...])
        times = ds["time"][:]
        dates = [Date(Dates.year(t), Dates.month(t), Dates.day(t)) for t in times]
        return dates, raw
    end
end

# Assemble one variable across the full archive span into a (date, col)
# DataFrame, applying the unit conversion and skipping years that fail to load.
# This is all of the network work; the caching wrapper below addresses it.
function _fetch_variable_full(lat, lon, scen, model, variant, grid, col)
    nexvar, conv = NEXGDDP_VARMAP[col]
    dates = Date[]
    vals = Union{Missing,Float64}[]
    for year in Dates.year(NEXGDDP_START):Dates.year(NEXGDDP_STOP)
        yscen = _scenario_for_year(year, scen)
        url = _nexgddp_url(NEXGDDP_BASE, model, yscen, variant, grid, nexvar, year)
        local res
        try
            res = _read_point_year(url, nexvar, lat, lon)
        catch err
            @warn "NEX-GDDP file unavailable, skipping" model year var = nexvar exception = err
            continue
        end
        ds_dates, ds_vals = res
        append!(dates, ds_dates)
        append!(vals, [ismissing(x) ? missing : conv(Float64(x)) for x in ds_vals])
    end
    # Every year failed to load (e.g. a network/TLS failure to the OPeNDAP host,
    # not a genuinely empty series) — error rather than return nothing, so the
    # caching layer never persists a failed fetch as an empty "success".
    isempty(dates) && error("NEX-GDDP returned no data for $model $col at " *
                            "($lat, $lon); every year-file read failed.")
    df = DataFrame(date = dates)
    df[!, col] = vals
    unique!(df, :date)          # guard against any calendar-induced duplicates
    sort!(df, :date)
    return df
end

# One full-span variable per cell, content-addressed and stored as Arrow. The
# archive never changes, so there is no stable/tail split (unlike ERA5): one
# entry per (model, scenario, variant, grid, var, cell) serves every date range.
@cached cachetype="climstats/nexgddp" ext="arrow" saver=_arrow_save loader=_arrow_load key=(a -> (; a.model, scenario=string(a.scenario), a.variant, a.grid, var=string(a.var), a.lat, a.lon)) function _nexgddp_var_cached(; model, scenario, variant, grid, var, lat, lon)
    return _fetch_variable_full(lat, lon, scenario, model, variant, grid, var)
end

function ClimStats.nexgddp_daily(loc::Location;
                                 scenario = :ssp245,
                                 model::AbstractString = "ACCESS-CM2",
                                 variant = nothing,
                                 grid = nothing,
                                 start::Date = NEXGDDP_START,
                                 stop::Date = NEXGDDP_STOP,
                                 vars = keys(NEXGDDP_VARMAP),
                                 cache::Bool = true)
    start <= stop || error("`start` ($start) must not be after `stop` ($stop).")
    scen = _normalize_scenario(scenario)
    v, g = nexgddp_model_spec(model; variant = variant, grid = grid)
    lat = _snap(loc.latitude)
    lon = _snap(loc.longitude)

    perdf = DataFrame[]
    for col in vars
        haskey(NEXGDDP_VARMAP, col) ||
            error("Unknown variable :$col. Choose from $(keys(NEXGDDP_VARMAP)).")
        full = _nexgddp_var_cached(; model, scenario = scen, variant = v, grid = g,
                                   var = col, lat, lon, cached = cache)
        push!(perdf, full[(full.date .>= start) .& (full.date .<= stop), :])
    end
    isempty(perdf) && error("No variables requested.")
    tbl = reduce((a, b) -> outerjoin(a, b; on = :date), perdf)
    sort!(tbl, :date)
    return ClimateData(loc, "NEX-GDDP $model $scen", tbl)
end

ClimStats.nexgddp_daily(place::AbstractString; kwargs...) =
    ClimStats.nexgddp_daily(geocode(place); kwargs...)

end # module ClimStatsNCDatasetsExt
