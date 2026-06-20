# Multi-model projection ensembles and their summary statistics.

"""
    Ensemble(location, members, models)

A collection of projection [`ClimateData`](@ref) for one location, one per
climate model. Build it with [`projection_ensemble`](@ref).
"""
struct Ensemble
    location::Location
    members::Vector{ClimateData}
    models::Vector{String}
end

function Base.show(io::IO, ::MIME"text/plain", ens::Ensemble)
    println(io, "Ensemble of ", length(ens.members), " models @ ", ens.location)
    print(io, "  models: ", join(ens.models, ", "))
end

"""
    projection_ensemble(place; models = PROJECTION_MODELS, kwargs...) -> Ensemble

Download a projection ensemble for `place` (a string or [`Location`](@ref)), one
member per entry of `models`. Models that fail to download are skipped with a
warning rather than aborting the whole ensemble. Remaining `kwargs` (`start`,
`stop`, `vars`, `timezone`) are forwarded to [`projection_daily`](@ref).

```julia
ens = projection_ensemble("Berlin, Germany")
```
"""
function projection_ensemble(place; models = PROJECTION_MODELS, kwargs...)
    loc = place isa Location ? place : geocode(place)
    members = ClimateData[]
    used = String[]
    for m in models
        try
            push!(members, projection_daily(loc; model = m, kwargs...))
            push!(used, m)
        catch err
            @warn "Skipping projection model $m" exception = err
        end
    end
    isempty(members) && error("No projection models could be downloaded for $loc.")
    return Ensemble(loc, members, used)
end

"""
    bias_correct(ens::Ensemble, obs::ClimateData; kwargs...) -> Ensemble

Bias-correct every member of an ensemble against the observed baseline `obs`
(see [`bias_correct`](@ref)). `kwargs` are forwarded to `fit_bias_correction`.
"""
bias_correct(ens::Ensemble, obs::ClimateData; kwargs...) =
    Ensemble(ens.location,
             [bias_correct(m, obs; kwargs...) for m in ens.members],
             ens.models)

"""
    ensemble_summary(dfs, valuecol; lo = 0.1, hi = 0.9) -> DataFrame

Combine several annual-index `DataFrame`s (one per model) into a per-year
summary across models. Returns columns `:year`, `:lo`, `:median`, `:hi`,
`:mean` and `:n` (number of models contributing that year). `lo`/`hi` are the
quantile levels of the spread band.
"""
function ensemble_summary(dfs::Vector{DataFrame}, valuecol::Symbol;
                          lo::Real = 0.1, hi::Real = 0.9)
    isempty(dfs) && error("ensemble_summary needs at least one DataFrame.")
    years = sort(unique(reduce(vcat, [df.year for df in dfs])))
    maps = [Dict(df.year .=> df[!, valuecol]) for df in dfs]
    n = length(years)
    med = Vector{Float64}(undef, n); lov = similar(med); hiv = similar(med)
    mn  = similar(med);              cnt = Vector{Int}(undef, n)
    for (i, y) in enumerate(years)
        vals = Float64[]
        for mp in maps
            haskey(mp, y) || continue
            x = mp[y]
            (ismissing(x) || (x isa AbstractFloat && isnan(x))) && continue
            push!(vals, Float64(x))
        end
        cnt[i] = length(vals)
        if isempty(vals)
            med[i] = lov[i] = hiv[i] = mn[i] = NaN
        else
            med[i] = median(vals)
            lov[i] = quantile(vals, lo)
            hiv[i] = quantile(vals, hi)
            mn[i]  = mean(vals)
        end
    end
    return DataFrame(year = years, lo = lov, median = med, hi = hiv, mean = mn, n = cnt)
end

"""
    ensemble_index(ens, indexfn; valuecol = nothing, lo = 0.1, hi = 0.9) -> DataFrame

Apply the annual-index function `indexfn` (a `ClimateData -> DataFrame` mapping,
e.g. `d -> days_above(d, 30)`) to every ensemble member and summarise the spread
with [`ensemble_summary`](@ref). The value column is auto-detected unless given.

```julia
ensemble_index(ens, d -> days_above(d, 30))
```
"""
function ensemble_index(ens::Ensemble, indexfn;
                        valuecol::Union{Nothing,Symbol} = nothing,
                        lo::Real = 0.1, hi::Real = 0.9)
    dfs = DataFrame[indexfn(m) for m in ens.members]
    vc = valuecol === nothing ? _default_valuecol(first(dfs)) : valuecol
    return ensemble_summary(dfs, vc; lo = lo, hi = hi)
end
