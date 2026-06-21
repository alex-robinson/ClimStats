# Nowcasting the trailing, incomplete calendar year by analog-year completion.
#
# ERA5 always stops a few days short of real time, so the final calendar year in
# a `ClimateData` is a partial year: a hot-day count or precip total computed on
# it is a misleading lower bound, an annual mean is seasonally biased. Rather
# than plot that partial value, we *complete* the year and report a statistical
# estimate with uncertainty.
#
# The method is analog resampling:
#   1. Compare the current year's observed window (Jan 1 … last available day)
#      against the same calendar window of every complete prior year, by RMSE of
#      the daily `var`. Closer years are better analogs.
#   2. Turn those distances into weights with a Gaussian kernel; optionally keep
#      only the top-K analogs.
#   3. For each analog year, take its days *after* the window as a candidate
#      trajectory for the rest of this year, anchored by shifting it so its
#      window mean matches the current year's (additive for temperatures,
#      multiplicative for precip — see `default_kind`). This tracks how the year
#      is actually running and preserves day-to-day structure within an analog.
#   4. Each anchored analog yields a *completed* daily series (one ensemble
#      member, flagged via an `:estimated` column). Running an index over the
#      members gives a weighted distribution → median and a lo–hi band.
#
# Index functions, `ClimateData`, and the originally-downloaded data are left
# untouched: completion produces new, separately-flagged `ClimateData`.

_doy_key(d::Date) = (Dates.month(d), Dates.day(d))

# Default variable to drive the analog similarity: prefer mean temperature as a
# general "what kind of year is this", else the first available variable.
function _default_sim_var(data::ClimateData)
    vars = variables(data)
    isempty(vars) && error("ClimateData has no variables to nowcast from.")
    return :tmean in vars ? :tmean : first(vars)
end

"""
    incomplete_final_year(data) -> Union{Int,Nothing}

The last calendar year of `data` if it does not reach 31 December (and so is a
partial year worth nowcasting), or `nothing` if the final year is complete.
"""
function incomplete_final_year(data::ClimateData)
    df = data.table
    isempty(df) && return nothing
    dmax = maximum(df.date)
    Y = Dates.year(dmax)
    return dmax >= Date(Y, 12, 31) ? nothing : Y
end

"""
    CurrentYearEstimate

Statistical estimate of an annual index for the trailing, incomplete year,
produced by [`estimate_current_year`](@ref) from weighted analog completions.

Fields
- `year`             : the incomplete calendar year.
- `n_obs`/`n_total`  : observed days so far / days in the full year.
- `observed_partial` : the index computed on the observed days only (for counts
  and sums this is a lower bound; shown for reference, not plotted).
- `median`,`lo`,`hi` : weighted median and lo–hi quantiles of the index across
  the completed analog members — the estimate and its uncertainty band.
- `members`          : per-analog `(; year, value, weight)` — the full weighted
  distribution behind the summary.
"""
struct CurrentYearEstimate
    year::Int
    n_obs::Int
    n_total::Int
    observed_partial::Float64
    median::Float64
    lo::Float64
    hi::Float64
    members::Vector{NamedTuple{(:year, :value, :weight),Tuple{Int,Float64,Float64}}}
end

function Base.show(io::IO, e::CurrentYearEstimate)
    @printf(io, "CurrentYearEstimate(%d: %.3g [%.3g–%.3g], %d/%d days, %d analogs)",
            e.year, e.median, e.lo, e.hi, e.n_obs, e.n_total, length(e.members))
end

# --- analog construction ----------------------------------------------------

# Per-variable, per-year lookup of daily values keyed by (month, day), skipping
# missing. `byvar[v][year][(m,d)] = value`.
function _value_index(df::DataFrame, vars)
    byvar = Dict(v => Dict{Int,Dict{Tuple{Int,Int},Float64}}() for v in vars)
    dates = df.date
    for v in vars
        col = df[!, v]
        dst = byvar[v]
        for i in eachindex(dates)
            x = col[i]
            ismissing(x) && continue
            yr = Dates.year(dates[i])
            yd = get!(dst, yr, Dict{Tuple{Int,Int},Float64}())
            yd[_doy_key(dates[i])] = Float64(x)
        end
    end
    return byvar
end

# Weighted quantile of `values` at probability `p` (NaN values dropped). Uses
# midpoint cumulative-weight positions, linearly interpolated.
function _weighted_quantile(values::Vector{Float64}, weights::Vector{Float64}, p::Real)
    keep = .!isnan.(values)
    v = values[keep]
    w = weights[keep]
    isempty(v) && return NaN
    sw = sum(w)
    sw <= 0 && return median(v)
    o = sortperm(v)
    v = v[o]
    w = w[o] ./ sw
    cum = cumsum(w)
    pos = cum .- w ./ 2          # Hazen-like position of each sorted value
    p = clamp(float(p), 0.0, 1.0)
    p <= pos[1] && return v[1]
    p >= pos[end] && return v[end]
    i = searchsortedlast(pos, p)
    t = (p - pos[i]) / (pos[i + 1] - pos[i])
    return v[i] + t * (v[i + 1] - v[i])
end

# Anchoring offset for variable `v`: how far the current year's window mean sits
# above the analog's, over the (month,day) keys present in both. Returns a value
# to add (additive) or multiply (multiplicative).
function _anchor(curkeys::Dict{Tuple{Int,Int},Float64},
                 anakeys::Dict{Tuple{Int,Int},Float64},
                 winkeys, kind::Symbol, maxscale::Real)
    cs = Float64[]
    as = Float64[]
    for k in winkeys
        (haskey(curkeys, k) && haskey(anakeys, k)) || continue
        push!(cs, curkeys[k]); push!(as, anakeys[k])
    end
    if isempty(cs)
        return kind === :additive ? 0.0 : 1.0
    end
    cm, am = mean(cs), mean(as)
    if kind === :additive
        return cm - am
    else
        return am > 1e-6 ? clamp(cm / am, 0.0, float(maxscale)) : 1.0
    end
end

# Build one completed daily series for analog year `A`: the full observed table
# (flagged `:estimated = false`) plus the year's remaining days filled from `A`
# and anchored to the current year, flagged `:estimated = true`.
function _completed_member(data::ClimateData, byvar, vars, Y::Int, A::Int,
                           winkeys, remaining_dates, maxscale)
    df = data.table
    tail = DataFrame(date = collect(remaining_dates))
    for v in vars
        kind = default_kind(v)
        curkeys = get(byvar[v], Y, Dict{Tuple{Int,Int},Float64}())
        anakeys = get(byvar[v], A, Dict{Tuple{Int,Int},Float64}())
        adj = _anchor(curkeys, anakeys, winkeys, kind, maxscale)
        vals = Vector{Union{Missing,Float64}}(undef, length(remaining_dates))
        for (j, r) in enumerate(remaining_dates)
            k = _doy_key(r)
            raw = get(anakeys, k, missing)
            raw === missing && k == (2, 29) && (raw = get(anakeys, (2, 28), missing))
            if raw === missing
                vals[j] = missing
            elseif kind === :additive
                vals[j] = raw + adj
            else
                vals[j] = max(0.0, raw * adj)
            end
        end
        tail[!, v] = vals
    end
    base = copy(df)
    base[!, :estimated] = falses(nrow(base))
    tail[!, :estimated] = trues(nrow(tail))
    full = vcat(base, select(tail, names(base)))
    return ClimateData(data.location, "$(data.source) (nowcast, analog $A)", full)
end

# Core: similarity weights + completed members for the incomplete final year.
# Returns (; year, n_obs, n_total, analogs) where `analogs` is a vector of
# (; year, weight, member::ClimateData) for the nonzero-weight analog years.
function _build_analogs(data::ClimateData;
                        var::Symbol,
                        n_analogs::Union{Nothing,Int} = 20,
                        bandwidth::Union{Nothing,Real} = nothing,
                        min_obs::Int = 7,
                        maxscale::Real = 10.0)
    df = data.table
    isempty(df) && error("Cannot nowcast empty ClimateData.")
    Y = incomplete_final_year(data)
    Y === nothing && error("The final year of $(data.source) is complete; nothing to nowcast.")
    hasproperty(df, var) ||
        error("Similarity variable :$var not present. Available: $(variables(data)).")

    dmax = maximum(df.date)
    n_total = Dates.value(Date(Y, 12, 31) - Date(Y, 1, 1)) + 1
    yrs = Dates.year.(df.date)
    winkeys = _doy_key.(df.date[yrs .== Y])      # observed (month,day) of year Y
    n_obs = length(winkeys)
    remaining_dates = (dmax + Day(1)):Day(1):Date(Y, 12, 31)

    vars = variables(data)
    byvar = _value_index(df, vars)

    # Candidate analogs: prior years with near-complete coverage (so they can
    # both match the window and fill the remaining days).
    daycount = Dict{Int,Int}()
    for y in yrs
        daycount[y] = get(daycount, y, 0) + 1
    end
    cand = sort([y for y in keys(daycount) if y < Y && daycount[y] >= 360])
    isempty(cand) && error("No complete prior year available to build analogs for $Y.")

    # RMSE of the similarity variable over the observed window, per candidate.
    curv = get(byvar[var], Y, Dict{Tuple{Int,Int},Float64}())
    rmse = map(cand) do A
        av = get(byvar[var], A, Dict{Tuple{Int,Int},Float64}())
        sq = Float64[]
        for k in winkeys
            (haskey(curv, k) && haskey(av, k)) || continue
            push!(sq, (curv[k] - av[k])^2)
        end
        isempty(sq) ? Inf : sqrt(mean(sq))
    end

    # Gaussian weights; with too few observed days fall back to flat climatology.
    if n_obs < min_obs || all(!isfinite, rmse)
        w = ones(length(cand))
    else
        finite = filter(isfinite, rmse)
        h = bandwidth === nothing ? max(median(finite), 1e-6) : float(bandwidth)
        w = [isfinite(r) ? exp(-(r / h)^2) : 0.0 for r in rmse]
    end
    # Keep only the top-K analogs, if requested.
    if n_analogs !== nothing && n_analogs < count(>(0), w)
        thresh = sort(w; rev = true)[n_analogs]
        w = [wi >= thresh ? wi : 0.0 for wi in w]
    end
    sw = sum(w)
    sw > 0 || error("All analog weights vanished for $Y.")
    w ./= sw

    analogs = NamedTuple{(:year, :weight, :member),Tuple{Int,Float64,ClimateData}}[]
    for (A, wi) in zip(cand, w)
        wi > 0 || continue
        member = _completed_member(data, byvar, vars, Y, A, winkeys, remaining_dates, maxscale)
        push!(analogs, (year = A, weight = wi, member = member))
    end
    return (year = Y, n_obs = n_obs, n_total = n_total, analogs = analogs)
end

# --- public API -------------------------------------------------------------

# Cached analog completion: one DataFrame stacking every completed member (full
# observed + filled rows), tagged with :_analog (the analog year) and :_weight
# (its normalised weight). This is the expensive, index-independent step; both
# public entry points reconstruct what they need from it, so the analog
# resampling runs once per (data, settings) regardless of which index is asked.
@cached cachetype="climstats/nowcast" ext="arrow" saver=_arrow_save loader=_arrow_load key=(a -> (; data=_content_hash(a.data), var=string(a.var), n_analogs=_key_opt(a.n_analogs), bandwidth=_key_opt(a.bandwidth), a.min_obs, a.maxscale)) function _analogs_cached(; data, var, n_analogs, bandwidth, min_obs, maxscale)
    built = _build_analogs(data; var, n_analogs, bandwidth, min_obs, maxscale)
    parts = DataFrame[]
    for a in built.analogs
        t = copy(a.member.table)
        t[!, :_analog] = fill(a.year, nrow(t))
        t[!, :_weight] = fill(a.weight, nrow(t))
        push!(parts, t)
    end
    isempty(parts) && error("No analogs produced for nowcast.")
    return reduce(vcat, parts)
end

# Reconstruct one analog member's ClimateData from a cached sub-frame.
function _member_from_group(data::ClimateData, sub)
    A = first(sub._analog)
    tbl = DataFrame(select(sub, Not([:_analog, :_weight])))
    return ClimateData(data.location, "$(data.source) (nowcast, analog $A)", tbl)
end

"""
    complete_current_year(data; var, n_analogs = 20, bandwidth, min_obs, maxscale, cache = true) -> Vector{ClimateData}

Build the ensemble of completed daily series for the trailing, incomplete year
of `data`: one [`ClimateData`](@ref) per weighted analog year, each the observed
history plus the year's remaining days filled from that analog and anchored to
how the current year is running. Every member carries a Boolean `:estimated`
column (`false` for observed days, `true` for filled days).

`var` (default mean temperature if present) drives the analog similarity; see the
module notes for the method. The completions are cached on disk keyed by the
content of `data` and the analog settings (`cache = false` recomputes). Errors
if the final year is already complete.
"""
function complete_current_year(data::ClimateData;
                               var::Symbol = _default_sim_var(data),
                               n_analogs::Union{Nothing,Int} = 20,
                               bandwidth::Union{Nothing,Real} = nothing,
                               min_obs::Int = 7,
                               maxscale::Real = 10.0,
                               cache::Bool = true)
    big = _analogs_cached(; data, var, n_analogs, bandwidth, min_obs,
                          maxscale = float(maxscale), cached = cache)
    return [_member_from_group(data, sub) for sub in groupby(big, :_analog)]
end

"""
    estimate_current_year(data, indexfn; var, valuecol, lo = 0.1, hi = 0.9, cache = true, kwargs...) -> CurrentYearEstimate

Estimate an annual index for the trailing, incomplete year of `data` by running
`indexfn` (a `ClimateData -> DataFrame` index, e.g. `d -> days_above(d, 30)`)
over the weighted analog completions from [`complete_current_year`](@ref) and
summarising the result as a weighted median with a `lo`–`hi` band.

`var` selects the variable the analog similarity keys on (default the index's
own variable when called from the high-level helpers); `valuecol` the index
column to summarise (auto-detected by default). Extra keyword arguments
(`n_analogs`, `bandwidth`, `min_obs`, `maxscale`) tune the analog builder and
`cache` toggles reuse of the (index-independent) completions. Returns a
[`CurrentYearEstimate`](@ref).
"""
function estimate_current_year(data::ClimateData, indexfn;
                               var::Symbol = _default_sim_var(data),
                               valuecol::Union{Nothing,Symbol} = nothing,
                               lo::Real = 0.1, hi::Real = 0.9,
                               n_analogs::Union{Nothing,Int} = 20,
                               bandwidth::Union{Nothing,Real} = nothing,
                               min_obs::Int = 7,
                               maxscale::Real = 10.0,
                               cache::Bool = true)
    Y = incomplete_final_year(data)
    Y === nothing &&
        error("The final year of $(data.source) is complete; nothing to nowcast.")
    big = _analogs_cached(; data, var, n_analogs, bandwidth, min_obs,
                          maxscale = float(maxscale), cached = cache)
    n_total = Dates.value(Date(Y, 12, 31) - Date(Y, 1, 1)) + 1
    n_obs = count(==(Y), Dates.year.(data.table.date))

    vc = valuecol
    yrs = Int[]; vals = Float64[]; ws = Float64[]
    for sub in groupby(big, :_analog)
        idf = indexfn(_member_from_group(data, sub))
        vc === nothing && (vc = _default_valuecol(idf))
        row = idf[idf.year .== Y, :]
        nrow(row) == 0 && continue
        x = row[1, vc]
        push!(yrs, first(sub._analog))
        push!(vals, (ismissing(x) || (x isa AbstractFloat && isnan(x))) ? NaN : Float64(x))
        push!(ws, first(sub._weight))
    end
    isempty(vals) && error("No analog produced an index value for $Y.")
    vc === nothing && (vc = :value)

    # The observed-only partial index, for reference.
    pdf = indexfn(data)
    prow = pdf[pdf.year .== Y, :]
    op = (nrow(prow) == 0 || ismissing(prow[1, vc])) ? NaN : Float64(prow[1, vc])

    members = [(year = yrs[i], value = vals[i], weight = ws[i]) for i in eachindex(vals)]
    return CurrentYearEstimate(Y, n_obs, n_total, op,
                               _weighted_quantile(vals, ws, 0.5),
                               _weighted_quantile(vals, ws, lo),
                               _weighted_quantile(vals, ws, hi),
                               members)
end
