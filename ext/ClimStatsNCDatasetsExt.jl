module ClimStatsNCDatasetsExt

# NetCDF/OPeNDAP reading for the NEX-GDDP-CMIP6 backend. Loaded automatically
# when the user does `using NCDatasets`. Everything pure (URLs, scenarios, unit
# conversion, the model registry) lives in ClimStats itself; this extension only
# adds the methods that actually open remote NetCDF files.

using ClimStats
using ClimStats: Location, ClimateData, geocode,
    NEXGDDP_BASE, NEXGDDP_VARMAP, nexgddp_model_spec, _normalize_scenario,
    _scenario_for_year, _nexgddp_url
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

# Assemble one variable across a span of years into a (date, col) DataFrame,
# applying the unit conversion and skipping years that fail to load.
function _fetch_variable(loc, scen, model, variant, grid, col, start, stop)
    nexvar, conv = NEXGDDP_VARMAP[col]
    dates = Date[]
    vals = Union{Missing,Float64}[]
    for year in Dates.year(start):Dates.year(stop)
        yscen = _scenario_for_year(year, scen)
        url = _nexgddp_url(NEXGDDP_BASE, model, yscen, variant, grid, nexvar, year)
        local res
        try
            res = _read_point_year(url, nexvar, loc.latitude, loc.longitude)
        catch err
            @warn "NEX-GDDP file unavailable, skipping" model year var = nexvar exception = err
            continue
        end
        ds_dates, ds_vals = res
        append!(dates, ds_dates)
        append!(vals, [ismissing(x) ? missing : conv(Float64(x)) for x in ds_vals])
    end
    df = DataFrame(date = dates)
    df[!, col] = vals
    df = df[(df.date .>= start) .& (df.date .<= stop), :]
    unique!(df, :date)          # guard against any calendar-induced duplicates
    return df
end

function ClimStats.nexgddp_daily(loc::Location;
                                 scenario = :ssp245,
                                 model::AbstractString = "ACCESS-CM2",
                                 variant = nothing,
                                 grid = nothing,
                                 start::Date = Date(1950, 1, 1),
                                 stop::Date = Date(2100, 12, 31),
                                 vars = keys(NEXGDDP_VARMAP))
    start <= stop || error("`start` ($start) must not be after `stop` ($stop).")
    scen = _normalize_scenario(scenario)
    v, g = nexgddp_model_spec(model; variant = variant, grid = grid)

    perdf = DataFrame[]
    for col in vars
        haskey(NEXGDDP_VARMAP, col) ||
            error("Unknown variable :$col. Choose from $(keys(NEXGDDP_VARMAP)).")
        push!(perdf, _fetch_variable(loc, scen, model, v, g, col, start, stop))
    end
    isempty(perdf) && error("No variables requested.")
    tbl = reduce((a, b) -> outerjoin(a, b; on = :date), perdf)
    sort!(tbl, :date)
    return ClimateData(loc, "NEX-GDDP $model $scen", tbl)
end

ClimStats.nexgddp_daily(place::AbstractString; kwargs...) =
    ClimStats.nexgddp_daily(geocode(place); kwargs...)

end # module ClimStatsNCDatasetsExt
