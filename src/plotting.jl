# Plotting helpers built on Makie (CairoMakie backend).
#
# Each public plot function returns a `Makie.Figure`, which you can `save` (re-
# exported from CairoMakie) or `display`. The mutating helpers draw into an
# `Axis`; they accept either an `Axis` or a `Figure` (whose first axis is used),
# so ERA5 history, ensemble bands and projections compose on one set of axes.

# A small, distinguishable colour cycle. Makie wants explicit colours, so we map
# the integer "series index" used throughout the plot helpers onto these.
const _PALETTE = [:steelblue, :firebrick, :seagreen, :darkorange,
                  :mediumpurple, :goldenrod]
_color(i::Integer) = _PALETTE[mod1(i, length(_PALETTE))]
_tocolor(c) = c isa Integer ? _color(c) : c

# Makie renders `NaN` as a gap; map `missing` to `NaN` so any value column plots.
_tofloatvec(y) = Float64[ismissing(v) ? NaN : Float64(v) for v in y]

_axis(ax::Axis) = ax
function _axis(fig::Figure)
    for c in fig.content
        c isa Axis && return c
    end
    error("No Axis found in figure.")
end

# Create a fresh Figure + Axis ready for index time series (no legend yet).
function _new_axis(; title = "", ylabel = "")
    fig = Figure()
    ax = Axis(fig[1, 1]; xlabel = "Year", ylabel = ylabel, title = title)
    return fig, ax
end

"""
    plot_index(yearly; valuecol, label = "ERA5", trend = true, title, ylabel) -> Figure

Plot an annual index `DataFrame` (as returned by [`days_above`](@ref),
[`annual_mean`](@ref), …) as a time series of `valuecol` against `:year`. When
`trend = true` a dashed least-squares trend line is added and its slope per year
is shown in the legend.

Returns a `Makie.Figure`, so you can `save("f.png", fig)`, `display` it, or draw
more series with [`plot_index!`](@ref) / [`plot_ensemble!`](@ref).
"""
function plot_index(yearly::DataFrame;
                    valuecol::Symbol = _default_valuecol(yearly),
                    label = "ERA5",
                    trend::Bool = true,
                    title = "",
                    ylabel = string(valuecol),
                    color = 1,
                    kwargs...)
    fig, ax = _new_axis(; title = title, ylabel = ylabel)
    plot_index!(ax, yearly; valuecol = valuecol, label = label,
                trend = trend, color = color, kwargs...)
    axislegend(ax; position = :lt)
    return fig
end

"""
    plot_index!(target, yearly; valuecol, label, trend, color, kwargs...) -> target

Draw an annual index series into `target` (an `Axis` or a `Figure`) as a line
with markers, optionally with a dashed trend line. Returns `target`.
"""
function plot_index!(target, yearly::DataFrame;
                     valuecol::Symbol = _default_valuecol(yearly),
                     label = "projection",
                     trend::Bool = true,
                     color = 1,
                     kwargs...)
    ax = _axis(target)
    col = _tocolor(color)
    x = yearly.year
    y = _tofloatvec(yearly[!, valuecol])
    scatterlines!(ax, x, y; color = col, markersize = 6, label = label, kwargs...)
    trend && _add_trend!(ax, x, y, label, col)
    return target
end

function _add_trend!(ax, x, y, label, color)
    tr = linear_trend(x, y)
    isfinite(tr.slope) || return ax
    lbl = (label === nothing || label == "") ?
        @sprintf("trend %+.2f/yr", tr.slope) :
        @sprintf("%s trend %+.2f/yr", label, tr.slope)
    xs = collect(x)
    lines!(ax, xs, tr.intercept .+ tr.slope .* xs;
           color = color, linewidth = 2, linestyle = :dash, label = lbl)
    return ax
end

"""
    plot_ensemble!(target, summary; label = "ensemble", band = true, color, kwargs...) -> target

Draw an ensemble summary (from [`ensemble_index`](@ref) / [`ensemble_summary`](@ref))
into `target`: the median as a line and, when `band = true`, the `lo`–`hi`
spread as a translucent shaded band.
"""
function plot_ensemble!(target, summary::DataFrame;
                        label = "ensemble", band::Bool = true,
                        color = 2, kwargs...)
    ax = _axis(target)
    col = _tocolor(color)
    x = summary.year
    med = _tofloatvec(summary.median)
    if band
        lo = _tofloatvec(summary.lo)
        hi = _tofloatvec(summary.hi)
        band!(ax, x, lo, hi; color = (col, 0.20))
    end
    lines!(ax, x, med; color = col, linewidth = 2, label = label, kwargs...)
    return target
end

# Build a figure pre-populated with the ERA5 history series (no legend yet), for
# the high-level helpers that then overlay ensembles before finalising.
function _figure_with_history(hist_idx, vc; title, ylabel)
    fig, ax = _new_axis(; title = title, ylabel = ylabel)
    plot_index!(ax, hist_idx; valuecol = vc, label = "ERA5",
                trend = false, color = 1)
    return fig, ax
end

"""
    plot_nowcast!(target, est; color = 1, label, markersize = 9, kwargs...) -> target

Overlay a [`CurrentYearEstimate`](@ref) for the incomplete final year onto
`target` (an `Axis` or `Figure`): a lighter-shade diamond marker at the weighted
median with a vertical `lo`–`hi` error bar, so it reads as an estimate distinct
from the solid observed history. Returns `target`.
"""
function plot_nowcast!(target, est::CurrentYearEstimate;
                       color = 1,
                       label = @sprintf("%d estimate", est.year),
                       markersize::Real = 9, kwargs...)
    ax = _axis(target)
    col = _tocolor(color)
    light = (col, 0.55)
    x = Float64(est.year)
    rangebars!(ax, [x], [est.lo], [est.hi]; color = light, linewidth = 2, whiskerwidth = 10)
    scatter!(ax, [x], [est.median]; color = light, marker = :diamond,
             markersize = markersize, label = label, kwargs...)
    return target
end

"""
    climate_timeseries(place; threshold = 30, var = :tmax, start, stop, nowcast = true, kwargs...) -> Figure

End-to-end convenience: geocode `place`, download ERA5, count the days per year
with `var` above `threshold`, and return the figure.

```julia
using ClimStats
fig = climate_timeseries("Berlin, Germany"; threshold = 30)
save("berlin_hot_days.png", fig)
```
"""
function climate_timeseries(place::AbstractString;
                            threshold::Real = 30,
                            var::Symbol = :tmax,
                            start::Date = Date(1950, 1, 1),
                            stop::Date = default_stop(),
                            nowcast::Bool = true,
                            kwargs...)
    data = era5_daily(place; start = start, stop = stop)
    yearly = days_above(data, threshold; var = var)
    loc = data.location
    place_lbl = isempty(loc.country) ? loc.name : "$(loc.name), $(loc.country)"
    title = @sprintf("%s — days/yr with %s > %g°C (ERA5)",
                     place_lbl, string(var), float(threshold))

    # The trailing year is partial; show it as a nowcast estimate (lighter marker
    # + error bar) rather than as a misleading partial count on the solid series.
    Yinc = nowcast ? incomplete_final_year(data) : nothing
    fig, ax = _new_axis(; title = title, ylabel = "days per year")
    solid = Yinc === nothing ? yearly : yearly[yearly.year .!= Yinc, :]
    plot_index!(ax, solid; valuecol = :days, label = "ERA5", kwargs...)
    if Yinc !== nothing
        est = estimate_current_year(data, d -> days_above(d, threshold; var = var);
                                    var = var, valuecol = :days)
        plot_nowcast!(ax, est; color = 1)
    end
    axislegend(ax; position = :lt)
    return fig
end

"""
    climate_projection(place; threshold, var, index, models, correct, ...) -> Figure

The headline projections figure: ERA5 history and a bias-corrected CMIP6
ensemble of the same index on one set of axes, with the ensemble spread shaded.

```julia
fig = climate_projection("Berlin, Germany"; threshold = 30)
save("berlin_hot_days_projection.png", fig)
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
- `nowcast`          : show the trailing, incomplete ERA5 year as a nowcast
  estimate (lighter marker + error bar) instead of a partial count (default
  `true`); see [`estimate_current_year`](@ref).
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
                            nowcast::Bool = true)
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
        @sprintf("%s — days/yr with %s > %g°C  ·  ERA5 + CMIP6 ensemble",
                 place_lbl, string(var), float(threshold)) :
        "$(place_lbl)  ·  ERA5 + CMIP6 ensemble"
    ylabel = index === nothing ? "days per year" : string(vc)

    # Drop the trailing partial ERA5 year from the solid history; it returns as a
    # nowcast estimate below.
    Yinc = nowcast ? incomplete_final_year(hist) : nothing
    solid = Yinc === nothing ? hist_idx : hist_idx[hist_idx.year .!= Yinc, :]

    fig, ax = _figure_with_history(solid, vc; title = title, ylabel = ylabel)
    if show_members
        for mem in ens.members
            mi = indexfn(mem)
            lines!(ax, mi.year, _tofloatvec(mi[!, vc]);
                   color = (:gray, 0.4), linewidth = 0.5)
        end
    end
    plot_ensemble!(ax, summary;
                   label = correct ? "CMIP6 (bias-corr.)" : "CMIP6",
                   band = band, color = 2)
    if Yinc !== nothing
        simvar = index === nothing ? var : _default_sim_var(hist)
        est = estimate_current_year(hist, indexfn; var = simvar, valuecol = vc)
        plot_nowcast!(ax, est; color = 1)
    end
    axislegend(ax; position = :lt)
    return fig
end
