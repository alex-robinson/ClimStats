# Climate indices computed from daily ClimateData.
#
# Each index reduces the daily table to one value per calendar year and returns
# a tidy DataFrame ready for plotting. Years are taken from the `:date` column.

# Pick a sensible value column of an annual-index DataFrame when the caller
# doesn't specify one. Shared by the plotting and nowcast helpers.
function _default_valuecol(df::DataFrame)
    for c in (:days, :mean, :total)
        hasproperty(df, c) && return c
    end
    cols = filter(c -> c ∉ (:year, :n_days), propertynames(df))
    isempty(cols) && error("Could not find a value column in $(propertynames(df)).")
    return first(cols)
end

"""
    annual_count(data, predicate; var = :tmax) -> DataFrame

For every calendar year, count the days on which `predicate(value)` is true,
where `value` is the daily `var`. Returns a `DataFrame` with columns
`:year`, `:days` (the count) and `:n_days` (days with valid data that year —
useful for spotting incomplete years).

```julia
annual_count(data, x -> x > 30; var = :tmax)   # hot days
```
"""
function annual_count(data::ClimateData, predicate::Function; var::Symbol = :tmax)
    df = data.table
    hasproperty(df, var) ||
        error("Variable :$var not present. Available: $(variables(data)).")
    work = DataFrame(year = Dates.year.(df.date), v = df[!, var])
    return combine(groupby(work, :year),
        :v => (x -> count(vi -> !ismissing(vi) && predicate(vi), x)) => :days,
        :v => (x -> count(!ismissing, x)) => :n_days)
end

"""
    days_above(data, threshold; var = :tmax) -> DataFrame

Number of days per year for which `var` is strictly greater than `threshold`
(°C for temperatures, mm for precipitation). The classic example —

```julia
days_above(data, 30)            # days/yr with Tmax > 30 °C
```
"""
days_above(data::ClimateData, threshold::Real; var::Symbol = :tmax) =
    annual_count(data, x -> x > threshold; var = var)

"""
    days_below(data, threshold; var = :tmin) -> DataFrame

Number of days per year for which `var` is strictly less than `threshold`.
"""
days_below(data::ClimateData, threshold::Real; var::Symbol = :tmin) =
    annual_count(data, x -> x < threshold; var = var)

# --- a few named ETCCDI-style indices --------------------------------------

"Days per year with Tmax > 30 °C."
hot_days(data)        = days_above(data, 30; var = :tmax)
"Summer days: Tmax > 25 °C."
summer_days(data)     = days_above(data, 25; var = :tmax)
"Frost days: Tmin < 0 °C."
frost_days(data)      = days_below(data, 0; var = :tmin)
"Icing days: Tmax < 0 °C (temperature stays below freezing all day)."
icing_days(data)      = days_below(data, 0; var = :tmax)
"Tropical nights: Tmin > 20 °C."
tropical_nights(data) = days_above(data, 20; var = :tmin)
"Wet days: precipitation ≥ 1 mm."
wet_days(data)        = annual_count(data, x -> x >= 1; var = :precip)

# --- continuous annual statistics ------------------------------------------

"""
    annual_mean(data; var = :tmean) -> DataFrame

Annual mean of `var`. Columns: `:year`, `:mean`, `:n_days`.
"""
function annual_mean(data::ClimateData; var::Symbol = :tmean)
    df = data.table
    hasproperty(df, var) ||
        error("Variable :$var not present. Available: $(variables(data)).")
    work = DataFrame(year = Dates.year.(df.date), v = df[!, var])
    return combine(groupby(work, :year),
        :v => (x -> (any(!ismissing, x) ? mean(skipmissing(x)) : missing)) => :mean,
        :v => (x -> count(!ismissing, x)) => :n_days)
end

"""
    annual_sum(data; var = :precip) -> DataFrame

Annual total of `var` (e.g. yearly precipitation). Columns: `:year`, `:total`,
`:n_days`.
"""
function annual_sum(data::ClimateData; var::Symbol = :precip)
    df = data.table
    hasproperty(df, var) ||
        error("Variable :$var not present. Available: $(variables(data)).")
    work = DataFrame(year = Dates.year.(df.date), v = df[!, var])
    return combine(groupby(work, :year),
        :v => (x -> (any(!ismissing, x) ? sum(skipmissing(x)) : missing)) => :total,
        :v => (x -> count(!ismissing, x)) => :n_days)
end

# --- climatological averages -----------------------------------------------

# Restrict a daily (date, value) frame to an inclusive span of calendar years.
# `period` is a `(first_year, last_year)` tuple, or `nothing` for the whole
# record. Returns a view-free copy ready for aggregation.
function _restrict_years(work::DataFrame, period)
    period === nothing && return work
    y = Dates.year.(work.date)
    return work[(y .>= first(period)) .& (y .<= last(period)), :]
end

"""
    daily_climatology(data; var = :tmean, window = 3, period = nothing) -> DataFrame

Climatological average of `var` for each day of the year. For every day-of-year
`d` (1…366) the mean is taken over every observation whose date falls within
`±window` days of `d` — wrapping across the year boundary — across all years in
`period`, an inclusive `(first_year, last_year)` tuple (or `nothing` for the
whole record). The window smooths the otherwise noisy single-day average.
Columns: `:doy`, `:mean`, `:n` (observations contributing to that day).

```julia
daily_climatology(data; var = :tmax, period = (1981, 2010))   # 30-yr normal
```
"""
function daily_climatology(data::ClimateData; var::Symbol = :tmean,
                           window::Integer = 3, period = nothing)
    df = data.table
    hasproperty(df, var) ||
        error("Variable :$var not present. Available: $(variables(data)).")
    work = _restrict_years(DataFrame(date = df.date, v = df[!, var]), period)
    doy  = Dates.dayofyear.(work.date)
    vals = work.v
    means  = Vector{Union{Missing,Float64}}(missing, 366)
    counts = zeros(Int, 366)
    for d in 1:366
        acc = 0.0; n = 0
        for i in eachindex(vals)
            vi = vals[i]
            ismissing(vi) && continue
            δ = abs(doy[i] - d)        # circular day-of-year distance (period 366)
            δ = min(δ, 366 - δ)
            δ <= window && (acc += vi; n += 1)
        end
        counts[d] = n
        n == 0 || (means[d] = acc / n)
    end
    return DataFrame(doy = 1:366, mean = means, n = counts)
end

"""
    monthly_climatology(data; var = :tmean, period = nothing) -> DataFrame

Climatological average of `var` for each calendar month (1…12), pooled over all
days in all years of `period` (an inclusive `(first_year, last_year)` tuple, or
`nothing` for the whole record). Columns: `:month`, `:mean`, `:n`.
"""
function monthly_climatology(data::ClimateData; var::Symbol = :tmean, period = nothing)
    df = data.table
    hasproperty(df, var) ||
        error("Variable :$var not present. Available: $(variables(data)).")
    work = _restrict_years(DataFrame(date = df.date, v = df[!, var]), period)
    work.month = Dates.month.(work.date)
    g = combine(groupby(work, :month),
        :v => (x -> (any(!ismissing, x) ? mean(skipmissing(x)) : missing)) => :mean,
        :v => (x -> count(!ismissing, x)) => :n)
    return sort!(g, :month)
end

"""
    monthly_means(data; var = :tmean) -> DataFrame

Mean of `var` for every (year, month) in the record — the per-year monthly means
that [`monthly_climatology`](@ref) averages over. Columns: `:year`, `:month`,
`:mean`, `:n_days`. Useful for plotting each year's seasonal cycle on its own.
"""
function monthly_means(data::ClimateData; var::Symbol = :tmean)
    df = data.table
    hasproperty(df, var) ||
        error("Variable :$var not present. Available: $(variables(data)).")
    work = DataFrame(year = Dates.year.(df.date), month = Dates.month.(df.date),
                     v = df[!, var])
    g = combine(groupby(work, [:year, :month]),
        :v => (x -> (any(!ismissing, x) ? mean(skipmissing(x)) : missing)) => :mean,
        :v => (x -> count(!ismissing, x)) => :n_days)
    return sort!(g, [:year, :month])
end

"""
    linear_trend(x, y) -> (; slope, intercept)

Ordinary least-squares fit of `y` against `x`, ignoring `missing`/`NaN` in `y`.
Returns `NaN` slope/intercept when fewer than two valid points exist.
"""
function linear_trend(x::AbstractVector, y::AbstractVector)
    keep = [!(ismissing(yi) || (yi isa AbstractFloat && isnan(yi))) for yi in y]
    xs = Float64.(x[keep])
    ys = Float64.(y[keep])
    length(xs) < 2 && return (slope = NaN, intercept = NaN)
    x̄, ȳ = mean(xs), mean(ys)
    sxx = sum(abs2, xs .- x̄)
    sxx == 0 && return (slope = NaN, intercept = NaN)
    slope = sum((xs .- x̄) .* (ys .- ȳ)) / sxx
    return (slope = slope, intercept = ȳ - slope * x̄)
end
