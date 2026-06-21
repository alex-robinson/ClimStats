# Bias adjustment of model data against an observational (ERA5) baseline.
#
# Two families of method are provided, selected via `method=` in
# `fit_bias_correction` / `bias_correct`:
#
#   :delta  — per-calendar-month mean correction (additive for temperatures,
#             multiplicative for precip). Fast, removes the mean seasonal bias,
#             but leaves the model's distribution shape untouched.
#
#   :qdm    — Quantile Delta Mapping (Cannon et al. 2015). Corrects the whole
#   :eqm     distribution per calendar month by matching quantiles to ERA5.
#             QDM additionally preserves the model's projected change at each
#             quantile (recommended for projections); EQM is plain empirical
#             quantile mapping. Both are additive for temperatures and
#             multiplicative for precipitation.
#
# All methods group by calendar month to respect seasonality and share the same
# fit/apply/convenience interface, so they are interchangeable everywhere
# (single series, ensembles, `climate_projection`).

"Default reference period for bias correction: the 1991–2020 WMO normal."
const DEFAULT_REF = (Date(1991, 1, 1), Date(2020, 12, 31))

"Pick the correction kind for a variable: precip is multiplicative, temps additive."
default_kind(var::Symbol) = var === :precip ? :multiplicative : :additive

"Supertype of fitted bias corrections; see [`BiasCorrection`](@ref) and [`QuantileCorrection`](@ref)."
abstract type AbstractBiasCorrection end

# --- fitted-correction types ------------------------------------------------

"""
    BiasCorrection <: AbstractBiasCorrection

A fitted per-month *mean* (delta) correction. Fields: `by` (grouping, `:month`),
`ref` (reference period), `kinds` (`var => :additive|:multiplicative`) and
`adjust` (`var => (month => offset-or-scale)`).
"""
struct BiasCorrection <: AbstractBiasCorrection
    by::Symbol
    ref::Tuple{Date,Date}
    kinds::Dict{Symbol,Symbol}
    adjust::Dict{Symbol,Dict{Int,Float64}}
end

function Base.show(io::IO, bc::BiasCorrection)
    @printf(io, "BiasCorrection(delta, ref=%s…%s, vars=%s)",
            bc.ref[1], bc.ref[2], join(sort(collect(keys(bc.kinds))), ","))
end

"""
    QuantileCorrection <: AbstractBiasCorrection

A fitted quantile-mapping correction (`kind` is `:qdm` or `:eqm`). Stores, per
variable and calendar month, the sorted ERA5 reference sample (`obs`), the
sorted model reference sample (`modref`) and the sorted full-period model sample
(`modfull`, used by QDM). `maxratio` caps multiplicative factors.
"""
struct QuantileCorrection <: AbstractBiasCorrection
    kind::Symbol
    by::Symbol
    ref::Tuple{Date,Date}
    kinds::Dict{Symbol,Symbol}
    obs::Dict{Symbol,Dict{Int,Vector{Float64}}}
    modref::Dict{Symbol,Dict{Int,Vector{Float64}}}
    modfull::Dict{Symbol,Dict{Int,Vector{Float64}}}
    maxratio::Float64
end

function Base.show(io::IO, qc::QuantileCorrection)
    @printf(io, "QuantileCorrection(%s, ref=%s…%s, vars=%s)",
            qc.kind, qc.ref[1], qc.ref[2], join(sort(collect(keys(qc.kinds))), ","))
end

# --- shared helpers ---------------------------------------------------------

_in_period(df::DataFrame, ref::Tuple{Date,Date}) =
    df[(df.date .>= ref[1]) .& (df.date .<= ref[2]), :]

function _month_mean(df::DataFrame, v::Symbol, m::Integer)
    hasproperty(df, v) || return NaN
    vals = df[Dates.month.(df.date) .== m, v]
    (isempty(vals) || !any(!ismissing, vals)) && return NaN
    return mean(skipmissing(vals))
end

# Sorted, missing-free sample of variable `v` for each calendar month.
function _month_samples(df::DataFrame, v::Symbol)
    d = Dict{Int,Vector{Float64}}()
    hasproperty(df, v) || return d
    months = Dates.month.(df.date)
    col = df[!, v]
    for m in 1:12
        vals = Float64[]
        for i in eachindex(col)
            months[i] == m || continue
            x = col[i]
            ismissing(x) && continue
            push!(vals, Float64(x))
        end
        sort!(vals)
        d[m] = vals
    end
    return d
end

# Empirical (interpolated) probability of `x` within a sorted sample,
# using Hazen plotting positions p_i = (i − 0.5)/n.
function _eprob(sorted::Vector{Float64}, x::Float64)
    n = length(sorted)
    n == 0 && return 0.5
    n == 1 && return 0.5
    x <= sorted[1]   && return 0.5 / n
    x >= sorted[end] && return (n - 0.5) / n
    i = searchsortedlast(sorted, x)        # sorted[i] <= x < sorted[i+1]
    i >= n && return (n - 0.5) / n
    x0, x1 = sorted[i], sorted[i + 1]
    p0, p1 = (i - 0.5) / n, (i + 0.5) / n
    t = x1 > x0 ? (x - x0) / (x1 - x0) : 0.0
    return clamp(p0 + t * (p1 - p0), 0.0, 1.0)
end

# Quantile of a pre-sorted sample at probability p (Statistics' default type 7).
function _quantile_sorted(sorted::Vector{Float64}, p::Float64)
    n = length(sorted)
    n == 0 && return NaN
    n == 1 && return sorted[1]
    h = (n - 1) * clamp(p, 0.0, 1.0) + 1
    lo = clamp(floor(Int, h), 1, n)
    hi = clamp(ceil(Int, h), 1, n)
    return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo])
end

# --- fit --------------------------------------------------------------------

"""
    fit_bias_correction(obs, model; method = :delta, ref, by, vars, kinds, maxscale, maxratio)

Fit a bias correction mapping `model` towards the observed baseline `obs`
(typically ERA5) over the reference period `ref` (default 1991–2020).

- `method`   : `:delta` (per-month mean), `:qdm` (quantile delta mapping) or
  `:eqm` (empirical quantile mapping).
- `vars`     : variables to correct (default: those shared by `obs` and `model`).
- `kinds`    : optional `var => :additive | :multiplicative` overrides.
- `maxscale` : cap on multiplicative factors for `:delta`.
- `maxratio` : cap on multiplicative ratios for `:qdm`.

Returns a [`BiasCorrection`](@ref) (`:delta`) or [`QuantileCorrection`](@ref)
(`:qdm`/`:eqm`); apply it with [`apply_bias_correction`](@ref).
"""
function fit_bias_correction(obs::ClimateData, model::ClimateData;
                             method::Symbol = :delta,
                             ref::Tuple{Date,Date} = DEFAULT_REF,
                             by::Symbol = :month,
                             vars = nothing,
                             kinds::Union{Nothing,AbstractDict} = nothing,
                             maxscale::Real = 10.0,
                             maxratio::Real = 10.0)
    by === :month || throw(ArgumentError("Only by=:month is supported (got :$by)."))
    if method === :delta
        return _fit_delta(obs, model; ref, vars, kinds, maxscale)
    elseif method === :qdm || method === :eqm
        return _fit_quantile(obs, model; kind = method, ref, vars, kinds, maxratio)
    else
        throw(ArgumentError("Unknown bias method :$method (use :delta, :qdm or :eqm)."))
    end
end

function _shared_vars(obs, model, vars)
    shared = vars === nothing ?
        intersect(variables(obs), variables(model)) : collect(vars)
    isempty(shared) && error("obs and model share no variables to correct.")
    return shared
end

function _fit_delta(obs, model; ref, vars, kinds, maxscale)
    shared = _shared_vars(obs, model, vars)
    odf = _in_period(obs.table, ref)
    mdf = _in_period(model.table, ref)
    kindmap = Dict{Symbol,Symbol}()
    adjust = Dict{Symbol,Dict{Int,Float64}}()
    for v in shared
        kind = (kinds !== nothing && haskey(kinds, v)) ? kinds[v] : default_kind(v)
        kindmap[v] = kind
        d = Dict{Int,Float64}()
        for m in 1:12
            o = _month_mean(odf, v, m)
            mo = _month_mean(mdf, v, m)
            if kind === :additive
                d[m] = (isnan(o) || isnan(mo)) ? 0.0 : o - mo
            else
                d[m] = (isnan(o) || isnan(mo) || mo <= 1e-6) ? 1.0 :
                       clamp(o / mo, 0.0, float(maxscale))
            end
        end
        adjust[v] = d
    end
    return BiasCorrection(:month, ref, kindmap, adjust)
end

function _fit_quantile(obs, model; kind, ref, vars, kinds, maxratio)
    shared = _shared_vars(obs, model, vars)
    odf = _in_period(obs.table, ref)
    mdf = _in_period(model.table, ref)
    fdf = model.table
    kindmap = Dict{Symbol,Symbol}()
    O  = Dict{Symbol,Dict{Int,Vector{Float64}}}()
    MR = Dict{Symbol,Dict{Int,Vector{Float64}}}()
    MF = Dict{Symbol,Dict{Int,Vector{Float64}}}()
    for v in shared
        kindmap[v] = (kinds !== nothing && haskey(kinds, v)) ? kinds[v] : default_kind(v)
        O[v]  = _month_samples(odf, v)
        MR[v] = _month_samples(mdf, v)
        MF[v] = _month_samples(fdf, v)
    end
    return QuantileCorrection(kind, :month, ref, kindmap, O, MR, MF, float(maxratio))
end

# --- apply ------------------------------------------------------------------

"""
    apply_bias_correction(model, fit::AbstractBiasCorrection) -> ClimateData

Apply a fitted correction (from [`fit_bias_correction`](@ref)) to `model`,
returning a new `ClimateData`. Multiplicative variables are floored at zero.
"""
function apply_bias_correction(model::ClimateData, bc::BiasCorrection)
    df = copy(model.table)
    months = Dates.month.(df.date)
    for (v, kind) in bc.kinds
        hasproperty(df, v) || continue
        adj = bc.adjust[v]
        col = df[!, v]
        new = Vector{Union{Missing,Float64}}(undef, length(col))
        @inbounds for i in eachindex(col)
            x = col[i]
            if ismissing(x)
                new[i] = missing
            elseif kind === :additive
                new[i] = x + get(adj, months[i], 0.0)
            else
                new[i] = max(0.0, x * get(adj, months[i], 1.0))
            end
        end
        df[!, v] = new
    end
    return ClimateData(model.location, model.source * " (bias-corrected)", df)
end

function apply_bias_correction(model::ClimateData, qc::QuantileCorrection)
    df = copy(model.table)
    months = Dates.month.(df.date)
    for (v, kind) in qc.kinds
        hasproperty(df, v) || continue
        col = df[!, v]
        new = Vector{Union{Missing,Float64}}(undef, length(col))
        obsv  = get(qc.obs, v, Dict{Int,Vector{Float64}}())
        mref  = get(qc.modref, v, Dict{Int,Vector{Float64}}())
        mfull = get(qc.modfull, v, Dict{Int,Vector{Float64}}())
        for i in eachindex(col)
            x = col[i]
            if ismissing(x)
                new[i] = missing
                continue
            end
            m = months[i]
            new[i] = _map_quantile(Float64(x),
                get(obsv, m, Float64[]), get(mref, m, Float64[]),
                get(mfull, m, Float64[]), qc.kind, kind, qc.maxratio)
        end
        df[!, v] = new
    end
    return ClimateData(model.location,
                       model.source * " (bias-corrected, $(qc.kind))", df)
end

function _map_quantile(x, obs, modref, modfull, qmkind, varkind, maxratio)
    (isempty(obs) || isempty(modref)) && return x
    if qmkind === :eqm
        τ = _eprob(modref, x)
        q = _quantile_sorted(obs, τ)
        return varkind === :multiplicative ? max(0.0, q) : q
    else  # :qdm — preserve the model's change at quantile τ
        ref = isempty(modfull) ? modref : modfull
        τ = _eprob(ref, x)
        xref = _quantile_sorted(modref, τ)
        obsq = _quantile_sorted(obs, τ)
        if varkind === :multiplicative
            ratio = xref > 1e-6 ? clamp(x / xref, 0.0, maxratio) : 1.0
            return max(0.0, obsq * ratio)
        else
            return obsq + (x - xref)
        end
    end
end

# --- convenience ------------------------------------------------------------

# Cached worker: fit + apply, returning just the corrected table (Arrow-friendly).
# Keyed on the content of both series plus every fit parameter, so an identical
# correction is computed once. The applied result is what callers want, and a
# fit object (nested Dicts) does not serialise as cleanly as the table.
@cached cachetype="climstats/biascorr" ext="arrow" saver=_arrow_save loader=_arrow_load key=(a -> (; model=_content_hash(a.model), obs=_content_hash(a.obs), method=string(a.method), ref=string.(a.ref), by=string(a.by), vars=_key_vars(a.vars), kinds=_key_kinds(a.kinds), a.maxscale, a.maxratio)) function _bias_correct_cached(; model, obs, method, ref, by, vars, kinds, maxscale, maxratio)
    fit = fit_bias_correction(obs, model; method, ref, by, vars, kinds, maxscale, maxratio)
    return apply_bias_correction(model, fit).table
end

"""
    bias_correct(model, obs; method = :delta, cache = true, kwargs...) -> ClimateData

Fit a correction of `model` towards `obs` and apply it in one step. `method` and
`kwargs` are forwarded to [`fit_bias_correction`](@ref). The corrected series is
cached on disk keyed by the content of both inputs and the fit parameters; pass
`cache = false` to recompute.
"""
function bias_correct(model::ClimateData, obs::ClimateData;
                      method::Symbol = :delta,
                      ref::Tuple{Date,Date} = DEFAULT_REF,
                      by::Symbol = :month,
                      vars = nothing,
                      kinds::Union{Nothing,AbstractDict} = nothing,
                      maxscale::Real = 10.0,
                      maxratio::Real = 10.0,
                      cache::Bool = true)
    tbl = _bias_correct_cached(; model, obs, method, ref, by, vars, kinds,
                               maxscale = float(maxscale), maxratio = float(maxratio),
                               cached = cache)
    src = method === :delta ? model.source * " (bias-corrected)" :
          model.source * " (bias-corrected, $method)"
    return ClimateData(model.location, src, tbl)
end
