# Core data types for ClimStats.

"""
    Location(name, country, latitude, longitude, elevation)

A geographic point on the Earth. Usually obtained from [`geocode`](@ref) but can
be constructed directly when you already know the coordinates.

Fields
- `name::String`      : human readable place name (e.g. `"Berlin"`)
- `country::String`   : country name (e.g. `"Germany"`)
- `latitude::Float64` : degrees north (−90 … 90)
- `longitude::Float64`: degrees east (−180 … 180)
- `elevation::Float64`: metres above sea level (`NaN` if unknown)
"""
struct Location
    name::String
    country::String
    latitude::Float64
    longitude::Float64
    elevation::Float64
end

Location(name, country, lat, lon) = Location(name, country, lat, lon, NaN)

function Base.show(io::IO, loc::Location)
    place = isempty(loc.country) ? loc.name : "$(loc.name), $(loc.country)"
    el = isnan(loc.elevation) ? "" : @sprintf(", %.0f m", loc.elevation)
    @printf(io, "Location(%s @ %.4f°N, %.4f°E%s)", place, loc.latitude, loc.longitude, el)
end

"""
    ClimateData(location, source, table)

A bundle of daily climate data for a single [`Location`](@ref).

- `location::Location` : where the data is from.
- `source::String`     : provenance, e.g. `"ERA5"` or a climate model name.
- `table::DataFrame`   : one row per day. The `:date` column holds `Date`s; the
  remaining columns are the available variables, any subset of:
    - `:tmax`   — daily maximum 2 m temperature  [°C]
    - `:tmin`   — daily minimum 2 m temperature  [°C]
    - `:tmean`  — daily mean 2 m temperature      [°C]
    - `:precip` — daily total precipitation       [mm]
  Missing values are stored as `missing`.

Use the helpers in `indices.jl` (e.g. [`days_above`](@ref)) to summarise it.
"""
struct ClimateData
    location::Location
    source::String
    table::DataFrame
end

"Return the underlying daily `DataFrame` of a [`ClimateData`](@ref)."
table(d::ClimateData) = d.table

"Return the climate variables (table columns excluding `:date`) available in `d`."
variables(d::ClimateData) = filter(!=(:date), propertynames(d.table))

function Base.show(io::IO, ::MIME"text/plain", d::ClimateData)
    df = d.table
    n = nrow(df)
    span = n == 0 ? "no data" : "$(minimum(df.date)) … $(maximum(df.date))"
    println(io, "ClimateData [", d.source, "]")
    println(io, "  location : ", d.location)
    println(io, "  period   : ", span, "  (", n, " days)")
    print(io,   "  variables: ", join(variables(d), ", "))
end
