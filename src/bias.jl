# Bias adjustment of model data against an observational (ERA5) baseline.
#
# Climate models carry systematic biases relative to reanalysis, so raw model
# values can't be compared to ERA5 (or fed into absolute-threshold indices like
# "days above 30 °C") directly. We correct each model towards ERA5 over a common
# reference period using a per-calendar-month delta:
#
#   * temperatures  -> additive       : corrected = model + (obs_mean − mod_mean)
#   * precipitation  -> multiplicative : corrected = model × (obs_mean / mod_mean)
#
# computed month-by-month over the reference period. This is the standard
# "delta-change" / mean bias correction. It removes the model's mean seasonal
# bias while preserving its climate-change signal. (A distribution-based method
# such as quantile mapping is a natural future refinement; the `BiasCorrection`
# type below is deliberately general enough to host one.)

"Default reference period for bias correction: the 1991–2020 WMO normal."
const DEFAULT_REF = (Date(1991, 1, 1), Date(2020, 12, 31))

"Pick the correction kind for a variable: precip is multiplicative, temps additive."
default_kind(var::Symbol) = var === :precip ? :multiplicative : :additive

"""
    BiasCorrection

A fitted bias-correction map, as produced by [`fit_bias_correction`](@ref) and
consumed by [`apply_bias_correction`](@ref).

Fields
- `by::Symbol`   : grouping used (currently `:month`).
- `ref`          : `(start, stop)` reference period the correction was fit on.
- `kinds`        : `var => :additive | :multiplicative`.
- `adjust`       : `var => (group => factor)`; the factor is an offset for
  additive variables and a scale for multiplicative ones.
"""
struct BiasCorrection
    by::Symbol
    ref::Tuple{Date,Date}
    kinds::Dict{Symbol,Symbol}
    adjust::Dict{Symbol,Dict{Int,Float64}}
end

function Base.show(io::IO, bc::BiasCorrection)
    @printf(io, "BiasCorrection(by=%s, ref=%s…%s, vars=%s)",
            bc.by, bc.ref[1], bc.ref[2], join(sort(collect(keys(bc.kinds))), ","))
end

_in_period(df::DataFrame, ref::Tuple{Date,Date}) =
    df[(df.date .>= ref[1]) .& (df.date .<= ref[2]), :]

function _month_mean(df::DataFrame, v::Symbol, m::Integer)
    hasproperty(df, v) || return NaN
    vals = df[Dates.month.(df.date) .== m, v]
    (isempty(vals) || !any(!ismissing, vals)) && return NaN
    return mean(skipmissing(vals))
end

"""
    fit_bias_correction(obs, model; ref, by, vars, kinds, maxscale) -> BiasCorrection

Fit a per-month bias correction that maps `model` towards the observed baseline
`obs` (typically ERA5) over the reference period `ref` (default 1991–2020).

Keyword arguments
- `ref`      : `(start, stop)` reference period.
- `by`       : grouping; only `:month` is currently supported.
- `vars`     : variables to correct (default: those shared by `obs` and `model`).
- `kinds`    : optional `var => :additive | :multiplicative` overrides.
- `maxscale` : cap on multiplicative scale factors (guards dry-month blow-ups).
"""
function fit_bias_correction(obs::ClimateData, model::ClimateData;
                             ref::Tuple{Date,Date} = DEFAULT_REF,
                             by::Symbol = :month,
                             vars = nothing,
                             kinds::Union{Nothing,AbstractDict} = nothing,
                             maxscale::Real = 10.0)
    by === :month || throw(ArgumentError("Only by=:month is supported (got :$by)."))
    shared = vars === nothing ?
        intersect(variables(obs), variables(model)) : collect(vars)
    isempty(shared) && error("obs and model share no variables to correct.")

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
    return BiasCorrection(by, ref, kindmap, adjust)
end

"""
    apply_bias_correction(model, bc::BiasCorrection) -> ClimateData

Apply a fitted [`BiasCorrection`](@ref) to `model`, returning a new
`ClimateData` whose corrected variables have the same monthly-mean climatology
as the baseline over the reference period. Multiplicative variables are floored
at zero.
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

"""
    bias_correct(model, obs; kwargs...) -> ClimateData

Convenience wrapper: fit a correction of `model` towards `obs` and apply it in
one step. `kwargs` are forwarded to [`fit_bias_correction`](@ref).
"""
bias_correct(model::ClimateData, obs::ClimateData; kwargs...) =
    apply_bias_correction(model, fit_bias_correction(obs, model; kwargs...))
