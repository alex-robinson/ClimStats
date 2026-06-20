# Plotting helpers built on Plots.jl.

"""
    plot_index(yearly; valuecol = :days, label = "ERA5", trend = true, kwargs...)

Plot an annual index `DataFrame` (as returned by [`days_above`](@ref),
[`annual_mean`](@ref), …) as a time series of `valuecol` against `:year`. When
`trend = true` a dashed least-squares trend line is overlaid and its slope per
year is shown in the legend. Extra `kwargs` are forwarded to `Plots.plot`.

Returns the `Plots.Plot`, so you can `display`, `savefig`, or further `plot!` it.
"""
function plot_index(yearly::DataFrame;
                    valuecol::Symbol = _default_valuecol(yearly),
                    label = "ERA5",
                    trend::Bool = true,
                    title = "",
                    ylabel = string(valuecol),
                    kwargs...)
    x = yearly.year
    y = yearly[!, valuecol]
    plt = plot(x, y;
        seriestype = :line, marker = :circle, markersize = 3,
        label = label, xlabel = "Year", ylabel = ylabel, title = title,
        legend = :topleft, framestyle = :box, kwargs...)
    trend && _add_trend!(plt, x, y, label)
    return plt
end

"""
    plot_index!(plt, yearly; valuecol, label, trend, kwargs...)

Overlay another annual index series onto an existing plot `plt` — handy for
drawing ERA5 history and a projection on the same axes.
"""
function plot_index!(plt, yearly::DataFrame;
                     valuecol::Symbol = _default_valuecol(yearly),
                     label = "projection",
                     trend::Bool = true,
                     kwargs...)
    x = yearly.year
    y = yearly[!, valuecol]
    plot!(plt, x, y;
        seriestype = :line, marker = :circle, markersize = 3,
        label = label, kwargs...)
    trend && _add_trend!(plt, x, y, label)
    return plt
end

# Pick a sensible value column when the caller doesn't specify one.
function _default_valuecol(df::DataFrame)
    for c in (:days, :mean, :total)
        hasproperty(df, c) && return c
    end
    cols = filter(c -> c ∉ (:year, :n_days), propertynames(df))
    isempty(cols) && error("Could not find a value column in $(propertynames(df)).")
    return first(cols)
end

function _add_trend!(plt, x, y, label)
    tr = linear_trend(x, y)
    isfinite(tr.slope) || return plt
    lbl = label === nothing || label == "" ?
        @sprintf("trend %+.2f/yr", tr.slope) :
        @sprintf("%s trend %+.2f/yr", label, tr.slope)
    plot!(plt, collect(x), tr.intercept .+ tr.slope .* collect(x);
        label = lbl, linewidth = 2, linestyle = :dash)
    return plt
end

"""
    climate_timeseries(place; threshold = 30, var = :tmax, start, stop, kwargs...) -> Plot

End-to-end convenience: geocode `place`, download ERA5, count the days per year
with `var` above `threshold`, and return the figure. This is the one-liner
behind the package's headline example.

```julia
using ClimStats
plt = climate_timeseries("Berlin, Germany"; threshold = 30)
savefig(plt, "berlin_hot_days.png")
```

Keyword arguments not listed here (`start`, `stop`, …) are passed to
[`era5_daily`](@ref); plotting `kwargs` go to [`plot_index`](@ref).
"""
function climate_timeseries(place::AbstractString;
                            threshold::Real = 30,
                            var::Symbol = :tmax,
                            start::Date = Date(1950, 1, 1),
                            stop::Date = default_stop(),
                            kwargs...)
    data = era5_daily(place; start = start, stop = stop)
    yearly = days_above(data, threshold; var = var)
    loc = data.location
    place_lbl = isempty(loc.country) ? loc.name : "$(loc.name), $(loc.country)"
    title = @sprintf("%s — days/yr with %s > %g°C\n(ERA5 via Open-Meteo)",
                     place_lbl, string(var), float(threshold))
    return plot_index(yearly; valuecol = :days, title = title,
                      ylabel = "days per year", label = "ERA5", kwargs...)
end

"""
    plot_ensemble!(plt, summary; label = "ensemble", band = true, kwargs...)

Overlay an ensemble summary (from [`ensemble_index`](@ref) /
[`ensemble_summary`](@ref)) onto plot `plt`: the median as a line and, when
`band = true`, the `lo`–`hi` spread as a shaded ribbon.
"""
function plot_ensemble!(plt, summary::DataFrame;
                        label = "ensemble", band::Bool = true, kwargs...)
    x = summary.year
    if band
        plot!(plt, x, summary.median;
            ribbon = (summary.median .- summary.lo, summary.hi .- summary.median),
            fillalpha = 0.20, linewidth = 2, label = label, kwargs...)
    else
        plot!(plt, x, summary.median; linewidth = 2, label = label, kwargs...)
    end
    return plt
end

"""
    climate_projection(place; threshold, var, index, models, correct, ...) -> Plot

The headline projections figure: ERA5 history and a bias-corrected CMIP6
ensemble of the same index on one set of axes, with the ensemble spread shaded.

```julia
plt = climate_projection("Berlin, Germany"; threshold = 30)
savefig(plt, "berlin_hot_days_projection.png")
```

Keyword arguments
- `threshold`, `var` : define the default index (days/yr with `var` > `threshold`).
- `index`            : optional custom `ClimateData -> DataFrame` index to use
  instead (e.g. `d -> annual_mean(d; var = :tmean)`).
- `models`           : ensemble members (default [`PROJECTION_MODELS`](@ref)).
- `correct`          : bias-correct members against ERA5 (default `true`).
- `method`           : bias-correction method, `:qdm` (default), `:eqm` or `:delta`.
- `ref`              : bias-correction reference period (default 1991–2020).
- `hist_start`/`hist_stop` : ERA5 period; `proj_start`/`proj_stop` : projection
  period (default 1950–2050).
- `show_members`     : also draw each member as a faint line (default `false`).
- `band`             : shade the ensemble spread (default `true`).
"""
function climate_projection(place::AbstractString;
                            threshold::Real = 30,
                            var::Symbol = :tmax,
                            index = nothing,
                            models = PROJECTION_MODELS,
                            correct::Bool = true,
                            method::Symbol = :qdm,
                            ref::Tuple{Date,Date} = DEFAULT_REF,
                            hist_start::Date = Date(1950, 1, 1),
                            hist_stop::Date = default_stop(),
                            proj_start::Date = Date(1950, 1, 1),
                            proj_stop::Date = Date(2050, 12, 31),
                            show_members::Bool = false,
                            band::Bool = true,
                            kwargs...)
    loc  = geocode(place)
    hist = era5_daily(loc; start = hist_start, stop = hist_stop)
    ens  = projection_ensemble(loc; models = models,
                               start = proj_start, stop = proj_stop)
    correct && (ens = bias_correct(ens, hist; method = method, ref = ref))

    indexfn = index === nothing ? (d -> days_above(d, threshold; var = var)) : index
    hist_idx = indexfn(hist)
    vc = _default_valuecol(hist_idx)
    summary = ensemble_index(ens, indexfn; valuecol = vc)

    place_lbl = isempty(loc.country) ? loc.name : "$(loc.name), $(loc.country)"
    title = index === nothing ?
        @sprintf("%s — days/yr with %s > %g°C\nERA5 + CMIP6 ensemble",
                 place_lbl, string(var), float(threshold)) :
        "$(place_lbl)\nERA5 + CMIP6 ensemble"
    ylabel = index === nothing ? "days per year" : string(vc)

    plt = plot_index(hist_idx; valuecol = vc, label = "ERA5", title = title,
                     ylabel = ylabel, trend = false, color = 1, kwargs...)
    if show_members
        for mem in ens.members
            mi = indexfn(mem)
            plot!(plt, mi.year, mi[!, vc];
                  label = "", linewidth = 0.5, linealpha = 0.35, color = :gray)
        end
    end
    plot_ensemble!(plt, summary;
                   label = correct ? "CMIP6 (bias-corr.)" : "CMIP6",
                   band = band, color = 2)
    return plt
end
