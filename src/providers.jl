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

const GEOCODE_URL  = "https://geocoding-api.open-meteo.com/v1/search"
const ARCHIVE_URL  = "https://archive-api.open-meteo.com/v1/archive"
const CLIMATE_URL  = "https://climate-api.open-meteo.com/v1/climate"
const FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

# Map ClimStats column names <-> Open-Meteo `daily` variable names.
const DAILY_VARMAP = (
    tmax   = "temperature_2m_max",
    tmin   = "temperature_2m_min",
    tmean  = "temperature_2m_mean",
    precip = "precipitation_sum",
)

"Default end date for ERA5 requests (the reanalysis lags real time by ~5 days)."
default_stop() = Dates.today() - Dates.Day(7)

# --- offline mode ----------------------------------------------------------
# When enabled, ClimStats makes no network requests: every value must come from
# the on-disk cache, and anything not cached (or inherently live, like the
# forecast) is skipped by the caller. Toggle with the `CLIMSTATS_OFFLINE`
# environment variable (read at load time, see `__init__`) or programmatically
# with `set_offline!`; the high-level plotting helpers also take an `offline`
# keyword.
const _OFFLINE = Ref(false)

struct OfflineError <: Exception
    url::String
end
Base.showerror(io::IO, e::OfflineError) = print(io,
    "ClimStats is offline; refusing to fetch ", e.url,
    ". Use cached data only, or disable offline mode (set_offline!(false)).")

"""
    set_offline!(b::Bool) -> Bool

Enable or disable offline mode (no network access; cached data only) and return
the previous setting. Offline mode can also be turned on at load time by setting
the `CLIMSTATS_OFFLINE` environment variable to `1`/`true`.
"""
set_offline!(b::Bool) = (old = _OFFLINE[]; _OFFLINE[] = b; old)

"Whether ClimStats is currently in offline mode (see [`set_offline!`](@ref))."
offline_mode() = _OFFLINE[]

# --- low level HTTP --------------------------------------------------------

# Open-Meteo enforces separate per-minute, per-hour and per-day request limits.
# The minutely cap is transient — it clears at the next clock minute — so on a
# `429` whose reason names the *minutely* limit we pause and retry, bounded by
# `minutely_retries`. The hourly/daily caps will not clear soon, so those (and
# any other non-200) are surfaced immediately rather than blocking pointlessly.
function _get_json(url::AbstractString, query::AbstractDict;
                   minutely_retries::Integer = 5, retry_pause::Real = 65)
    _OFFLINE[] && throw(OfflineError(url))
    for attempt in 0:minutely_retries
        resp = try
            HTTP.get(url; query = query, status_exception = false, retry = true)
        catch err
            error("ClimStats could not reach $url. This package needs network " *
                  "access to download data. Underlying error: $err")
        end
        resp.status == 200 && return JSON3.read(resp.body)
        body = String(resp.body)
        if resp.status == 429 && occursin(r"minutely"i, body) && attempt < minutely_retries
            @info "Open-Meteo minutely request limit hit; pausing $(retry_pause)s " *
                  "before retry $(attempt + 1)/$(minutely_retries)" url
            sleep(retry_pause)
            continue
        end
        error("Request to $url failed (HTTP $(resp.status)). Response: $body")
    end
end

# Open-Meteo sends `null` for gaps; JSON3 decodes that to `nothing`.
_tofloat(x) = x === nothing ? missing : Float64(x)

"Build the standard daily DataFrame from an Open-Meteo `daily` JSON object."
function _build_table(daily)
    haskey(daily, :time) || error("Unexpected response: no `daily.time` field.")
    times = String.(daily.time)
    # The Open-Meteo climate (CMIP6) API can return a `time` axis one element
    # longer than the data arrays; align everything to the shortest common length
    # so the columns stay consistent (a no-op when lengths already match).
    n = length(times)
    for (_, omname) in pairs(DAILY_VARMAP)
        key = Symbol(omname)
        haskey(daily, key) && (n = min(n, length(daily[key])))
    end
    df = DataFrame(date = Date.(times[1:n]))
    for (col, omname) in pairs(DAILY_VARMAP)
        key = Symbol(omname)
        haskey(daily, key) || continue
        df[!, col] = Vector{Union{Missing,Float64}}(_tofloat.(daily[key])[1:n])
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

The resolved location is cached on disk (keyed by the query string), so a place
looked up once is available later even in offline mode (pass `cache = false` to
force a fresh lookup).
"""
function geocode(place::AbstractString; results::Integer = 10, language = "en",
                 cache::Bool = true)
    df = _geocode_cached(; place = String(strip(place)), results = Int(results),
                         language = String(language), cached = cache)
    r = df[1, :]
    return Location(r.name, r.country, r.latitude, r.longitude, r.elevation)
end

# Cached geocode result, stored as a one-row DataFrame so it round-trips through
# the same Arrow codec as the data caches. Network + disambiguation live in
# `_geocode_live`; only the chosen location is persisted.
@cached cachetype="climstats/geocode" ext="arrow" saver=_arrow_save loader=_arrow_load key=(a -> (; a.place, a.results, a.language)) function _geocode_cached(; place, results, language)
    loc = _geocode_live(place; results = results, language = language)
    return DataFrame(name = [loc.name], country = [loc.country],
                     latitude = [loc.latitude], longitude = [loc.longitude],
                     elevation = [loc.elevation])
end

# The live geocoding request and match selection (no caching).
function _geocode_live(place::AbstractString; results::Integer = 10, language = "en")
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
    # those slivers fetched live and spliced on — they are never cached. In
    # offline mode the live splices are skipped: only the cached stable history
    # is returned (clipped to the requested range below).
    if !_OFFLINE[]
        start < ERA5_EPOCH &&
            (df = vcat(_fetch_era5_raw(lat, lon, allvars, start, ERA5_EPOCH - Day(1),
                                       timezone), df))
        stop > through &&
            (df = vcat(df, _fetch_era5_raw(lat, lon, allvars, through + Day(1), stop,
                                           timezone)))
    end

    df = df[(df.date .>= start) .& (df.date .<= stop), :]
    return ClimateData(loc, "ERA5", select(df, :date, collect(vars)...))
end

# --- live forecast ---------------------------------------------------------

"""
    forecast_daily(place; days = 7, vars, timezone) -> ClimateData
    forecast_daily(location::Location; days, vars, timezone) -> ClimateData

Daily weather *forecast* for a location from the Open-Meteo forecast API, today
through `days - 1` days ahead. Same column convention as [`era5_daily`](@ref)
(`:date` plus the requested `:tmax`/`:tmin`/`:tmean`/`:precip`), so the index and
plotting helpers apply unchanged. The `source` label is `"forecast"`.

Unlike ERA5 and CMIP6 this is a small, fast-changing live request and is **not**
cached on disk — each call fetches fresh, at the exact location (no grid snap).

```julia
fc = forecast_daily("Berlin, Germany"; days = 7)
fc.table[fc.table.date .== Dates.today(), :]   # today's forecast row
```
"""
forecast_daily(place::AbstractString; kwargs...) = forecast_daily(geocode(place); kwargs...)

function forecast_daily(loc::Location;
                        days::Integer = 7,
                        vars = keys(DAILY_VARMAP),
                        timezone = "auto")
    for v in vars
        haskey(DAILY_VARMAP, v) || error("Unknown variable :$v. Choose from " *
                                         "$(collect(keys(DAILY_VARMAP))).")
    end
    json = _get_json(FORECAST_URL, Dict(
        "latitude"      => string(loc.latitude),
        "longitude"     => string(loc.longitude),
        "daily"         => _daily_param(vars),
        "forecast_days" => string(days),
        "timezone"      => timezone,
    ))
    haskey(json, :daily) ||
        error("Open-Meteo forecast returned no data for $loc.")
    df = _build_table(json.daily)
    return ClimateData(loc, "forecast", select(df, :date, collect(vars)...))
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
    projection_daily(location::Location; model, start, stop, vars, timezone, cache)

Download daily CMIP6 climate-projection data for a single location (1950–2050).
The full fixed span is cached on disk per model and grid cell (pass
`cache = false` to re-download), so repeated calls are served locally.
Same return type and column convention as [`era5_daily`](@ref), so all of the
index and plotting helpers apply directly.

```julia
proj = projection_daily("Berlin, Germany"; model = "MRI_AGCM3_2_S")
```

See [`PROJECTION_MODELS`](@ref) for available `model` names.
"""
projection_daily(place::AbstractString; kwargs...) =
    projection_daily(geocode(place); kwargs...)

"Fixed span of the Open-Meteo CMIP6 projection (1950 history → 2050 projection)."
const PROJECTION_EPOCH = Date(1950, 1, 1)
const PROJECTION_STOP  = Date(2050, 12, 31)

# Raw Open-Meteo climate-API fetch for one model/cell: all the network work.
function _fetch_projection_raw(model, lat, lon, vars, start::Date, stop::Date, timezone)
    json = _get_json(CLIMATE_URL, Dict(
        "latitude"   => string(lat),
        "longitude"  => string(lon),
        "start_date" => string(start),
        "end_date"   => string(stop),
        "models"     => model,
        "daily"      => _daily_param(vars),
        "timezone"   => timezone,
    ))
    haskey(json, :daily) ||
        error("Open-Meteo climate API returned no data for ($lat, $lon).")
    return _build_table(json.daily)
end

# Cached full-span projection per (model, snapped cell). The CMIP6 projection is
# a fixed 1950–2050 series (it does not update over time), so — like NEX-GDDP and
# unlike ERA5 — there is no live tail: one fetch per model/cell serves every
# requested date range and variable subset.
@cached cachetype="climstats/projection" ext="arrow" saver=_arrow_save loader=_arrow_load key=(a -> (; a.model, a.lat, a.lon)) function _projection_full(; model, lat, lon, _timezone = "auto")
    return _fetch_projection_raw(model, lat, lon, collect(keys(DAILY_VARMAP)),
                                 PROJECTION_EPOCH, PROJECTION_STOP, _timezone)
end

function projection_daily(loc::Location;
                          model::AbstractString = "MRI_AGCM3_2_S",
                          start::Date = PROJECTION_EPOCH,
                          stop::Date  = PROJECTION_STOP,
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
    df = _projection_full(; model, lat, lon, _timezone = timezone, cached = cache)
    df = df[(df.date .>= start) .& (df.date .<= stop), :]
    return ClimateData(loc, model, select(df, :date, collect(vars)...))
end
