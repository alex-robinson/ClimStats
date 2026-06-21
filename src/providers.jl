# Data providers: turn a place / coordinate into daily ClimateData.
#
# This start uses the free, key-less Open-Meteo APIs:
#   * geocoding  -> coordinates           (geocoding-api.open-meteo.com)
#   * archive    -> ERA5 reanalysis       (archive-api.open-meteo.com)
#   * climate    -> CMIP6 projections      (climate-api.open-meteo.com)
#
# Everything below funnels through `_get_json` and `_build_table`, so adding a
# different backend later (e.g. a native Copernicus CDS downloader) only means
# returning a `ClimateData` with the same column convention — nothing else in
# the package needs to change.

const GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
const ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
const CLIMATE_URL = "https://climate-api.open-meteo.com/v1/climate"

# Map ClimStats column names <-> Open-Meteo `daily` variable names.
const DAILY_VARMAP = (
    tmax   = "temperature_2m_max",
    tmin   = "temperature_2m_min",
    tmean  = "temperature_2m_mean",
    precip = "precipitation_sum",
)

"Default end date for ERA5 requests (the reanalysis lags real time by ~5 days)."
default_stop() = Dates.today() - Dates.Day(7)

# --- low level HTTP --------------------------------------------------------

function _get_json(url::AbstractString, query::AbstractDict)
    resp = try
        HTTP.get(url; query = query, status_exception = false, retry = true)
    catch err
        error("ClimStats could not reach $url. This package needs network " *
              "access to download data. Underlying error: $err")
    end
    if resp.status != 200
        body = String(resp.body)
        error("Request to $url failed (HTTP $(resp.status)). Response: $body")
    end
    return JSON3.read(resp.body)
end

# Open-Meteo sends `null` for gaps; JSON3 decodes that to `nothing`.
_tofloat(x) = x === nothing ? missing : Float64(x)

"Build the standard daily DataFrame from an Open-Meteo `daily` JSON object."
function _build_table(daily)
    haskey(daily, :time) || error("Unexpected response: no `daily.time` field.")
    df = DataFrame(date = Date.(String.(daily.time)))
    for (col, omname) in pairs(DAILY_VARMAP)
        key = Symbol(omname)
        if haskey(daily, key)
            df[!, col] = Vector{Union{Missing,Float64}}(_tofloat.(daily[key]))
        end
    end
    return df
end

function _daily_param(vars)
    names = String[]
    for v in vars
        haskey(DAILY_VARMAP, v) || error("Unknown variable :$v. Choose from " *
                                         "$(collect(keys(DAILY_VARMAP))).")
        push!(names, DAILY_VARMAP[v])
    end
    return join(names, ",")
end

# --- geocoding -------------------------------------------------------------

"""
    geocode(place; results = 10, language = "en") -> Location

Resolve a free-text place description such as `"Berlin, Germany"` to a
[`Location`](@ref). The part before the first comma is used as the search term;
anything after it (country, country code, or region) is used to disambiguate
between matches.

```julia
geocode("Berlin, Germany")
geocode("Paris, France")
geocode("Springfield, US")
```
"""
function geocode(place::AbstractString; results::Integer = 10, language = "en")
    parts = strip.(split(place, ","))
    query_name = String(parts[1])
    filt = length(parts) > 1 ? lowercase(String(parts[end])) : nothing

    json = _get_json(GEOCODE_URL, Dict(
        "name"     => query_name,
        "count"    => string(results),
        "language" => language,
        "format"   => "json",
    ))
    (haskey(json, :results) && !isempty(json.results)) ||
        error("No location found for \"$place\".")

    cands = json.results
    chosen = nothing
    if filt !== nothing
        for c in cands
            country = lowercase(String(get(c, :country, "")))
            cc      = lowercase(String(get(c, :country_code, "")))
            admin1  = lowercase(String(get(c, :admin1, "")))
            if occursin(filt, country) || filt == cc || occursin(filt, admin1)
                chosen = c
                break
            end
        end
    end
    chosen === nothing && (chosen = first(cands))

    return Location(
        String(get(chosen, :name, query_name)),
        String(get(chosen, :country, "")),
        Float64(chosen.latitude),
        Float64(chosen.longitude),
        Float64(get(chosen, :elevation, NaN)),
    )
end

# --- ERA5 (historical reanalysis) ------------------------------------------

"""
    era5_daily(place; kwargs...) -> ClimateData
    era5_daily(location::Location; start, stop, vars, timezone) -> ClimateData

Download daily ERA5 reanalysis for a single location. A place string is
geocoded automatically:

```julia
data = era5_daily("Berlin, Germany")
data = era5_daily("Berlin, Germany"; start = Date(1980,1,1), stop = Date(2024,12,31))
```

Keyword arguments
- `start::Date`    : first day (default `1950-01-01`; ERA5 reaches back to 1940).
- `stop::Date`     : last day (default ≈ today − 7 days).
- `vars`           : variables to return (default all of
  `(:tmax, :tmin, :tmean, :precip)`).
- `timezone`       : timezone for daily aggregation (default `"auto"`, i.e. the
  location's local time, so "days" align with the local calendar).
- `cache::Bool`    : reuse an on-disk copy of the series instead of re-downloading
  (default `true`); pass `false` to force a fresh fetch.

Data are ERA5/ERA5-Land served by the Open-Meteo archive API.

Caching (see `src/cache.jl`): the request point is snapped to the 0.25° ERA5
grid and the stable history is stored once per cell as Arrow, so any later call
for the same cell — at any date range or variable subset — is served from disk.
Only the recent, still-changing tail is fetched live each time; the stable cache
rolls forward once a month, which is also when newly-finalised ERA5 values
replace the preliminary ERA5T edge.
"""
era5_daily(place::AbstractString; kwargs...) = era5_daily(geocode(place); kwargs...)

"First day of the ERA5 history we cache from (the archive itself reaches to 1940)."
const ERA5_EPOCH = Date(1950, 1, 1)

# Raw Open-Meteo archive fetch for one cell: all of the network work, no caching.
function _fetch_era5_raw(lat, lon, vars, start::Date, stop::Date, timezone)
    json = _get_json(ARCHIVE_URL, Dict(
        "latitude"   => string(lat),
        "longitude"  => string(lon),
        "start_date" => string(start),
        "end_date"   => string(stop),
        "daily"      => _daily_param(vars),
        "timezone"   => timezone,
    ))
    haskey(json, :daily) ||
        error("Open-Meteo archive returned no data for ($lat, $lon).")
    return _build_table(json.daily)
end

# The stable history [ERA5_EPOCH, through], content-addressed and stored as Arrow.
# Always all four variables (per-cell reuse beats per-variable thrift for a tiny
# series), so the key carries no `vars`. `through` rolls once a month, so the key
# both gains newly-available days and re-pulls the range — letting final ERA5
# overwrite the preliminary ERA5T edge. `_timezone` is excluded from the hash.
@cached cachetype="climstats/era5" ext="arrow" saver=_arrow_save loader=_arrow_load key=(a -> (; a.lat, a.lon, through = string(a.through))) function _era5_stable(; lat, lon, through::Date, _timezone = "auto")
    return _fetch_era5_raw(lat, lon, collect(keys(DAILY_VARMAP)),
                           ERA5_EPOCH, through, _timezone)
end

function era5_daily(loc::Location;
                    start::Date = ERA5_EPOCH,
                    stop::Date  = default_stop(),
                    vars = keys(DAILY_VARMAP),
                    timezone = "auto",
                    cache::Bool = true)
    start <= stop || error("`start` ($start) must not be after `stop` ($stop).")
    for v in vars
        haskey(DAILY_VARMAP, v) || error("Unknown variable :$v. Choose from " *
                                         "$(collect(keys(DAILY_VARMAP))).")
    end
    lat = _snap(loc.latitude)
    lon = _snap(loc.longitude)
    through = _last_complete_month_end(default_stop())
    allvars = collect(keys(DAILY_VARMAP))

    df = _era5_stable(; lat, lon, through, _timezone = timezone, cached = cache)
    # Requests reaching before the cached epoch or past the stable boundary get
    # those slivers fetched live and spliced on — they are never cached.
    start < ERA5_EPOCH &&
        (df = vcat(_fetch_era5_raw(lat, lon, allvars, start, ERA5_EPOCH - Day(1),
                                   timezone), df))
    stop > through &&
        (df = vcat(df, _fetch_era5_raw(lat, lon, allvars, through + Day(1), stop,
                                       timezone)))

    df = df[(df.date .>= start) .& (df.date .<= stop), :]
    return ClimateData(loc, "ERA5", select(df, :date, collect(vars)...))
end

# --- CMIP6 (climate projections) -------------------------------------------
#
# Groundwork for the "projections" step. Same column convention as ERA5, so the
# index/plot helpers work on it unchanged.

"A few CMIP6 downscaled models offered by the Open-Meteo climate API."
const PROJECTION_MODELS = [
    "MRI_AGCM3_2_S",
    "EC_Earth3P_HR",
    "MPI_ESM1_2_XR",
    "NICAM16_8S",
    "CMCC_CM2_VHR4",
    "FGOALS_f3_H",
]

"""
    projection_daily(place; kwargs...) -> ClimateData
    projection_daily(location::Location; model, start, stop, vars, timezone)

Download daily CMIP6 climate-projection data for a single location (1950–2050).
Same return type and column convention as [`era5_daily`](@ref), so all of the
index and plotting helpers apply directly.

```julia
proj = projection_daily("Berlin, Germany"; model = "MRI_AGCM3_2_S")
```

See [`PROJECTION_MODELS`](@ref) for available `model` names.
"""
projection_daily(place::AbstractString; kwargs...) =
    projection_daily(geocode(place); kwargs...)

function projection_daily(loc::Location;
                          model::AbstractString = "MRI_AGCM3_2_S",
                          start::Date = Date(1950, 1, 1),
                          stop::Date  = Date(2050, 12, 31),
                          vars = keys(DAILY_VARMAP),
                          timezone = "auto")
    start <= stop || error("`start` ($start) must not be after `stop` ($stop).")
    json = _get_json(CLIMATE_URL, Dict(
        "latitude"   => string(loc.latitude),
        "longitude"  => string(loc.longitude),
        "start_date" => string(start),
        "end_date"   => string(stop),
        "models"     => model,
        "daily"      => _daily_param(vars),
        "timezone"   => timezone,
    ))
    haskey(json, :daily) || error("Open-Meteo climate API returned no data for $loc.")
    return ClimateData(loc, model, _build_table(json.daily))
end
