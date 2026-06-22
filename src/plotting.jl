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

# Climate-Pulse (Copernicus C3S) inspired palette for the seasonal-cycle figures:
# the most recent years pop in warm tones over a light-grey "spaghetti" of every
# year, with the climatological mean as a dashed grey line and the future
# projection band in a muted magenta.
const CP_SPAGHETTI = "#d6d6d6"   # every historical year (faint background)
const CP_AVERAGE   = "#555555"   # climatological mean (dashed)
const CP_FUTURE    = "#b22222"   # future projection band (dark red, drawn very translucent)
# Accent for the most recent years, current year last: gold → coral → burgundy.
const CP_YEARS = ("#e0a23c", "#e0503a", "#7d2a35")

# Colours for the `n` most recent years (oldest → newest), taken from the end of
# CP_YEARS so the current year is always burgundy. `n` is clamped to what we have.
_recent_year_colors(n::Integer) = CP_YEARS[(length(CP_YEARS) - min(n, length(CP_YEARS)) + 1):end]

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

const _MONTH_ABBR = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
# Day-of-year of the first of each month (non-leap), for day-of-year axis ticks.
const _MONTH_STARTS = [Dates.dayofyear(Date(2001, m, 1)) for m in 1:12]

_place_label(loc) = isempty(loc.country) ? loc.name : "$(loc.name), $(loc.country)"

# Run `f()` with offline mode forced to `offline`, restoring the prior setting
# afterwards. Used by the high-level helpers to honour their `offline` keyword
# (which also gates the geocoding call in their string methods).
function _with_offline(f, offline::Bool)
    prev = set_offline!(offline)
    try
        return f()
    finally
        set_offline!(prev)
    end
end

# Climatological mean of `var` on a single day-of-year, ±window window, over the
# given inclusive `(first_year, last_year)` period. `missing` if no observations.
function _doy_clim(data::ClimateData, var::Symbol, doy::Integer; window, period)
    c = daily_climatology(data; var = var, window = window, period = period)
    return only(c[c.doy .== doy, :mean])
end

# (tmin, tmean, tmax) climatology on `doy` for one ClimateData …
function _day_bar(data::ClimateData, doy; window, period)
    f(v) = _doy_clim(data, v, doy; window = window, period = period)
    return (lo = f(:tmin), mid = f(:tmean), hi = f(:tmax))
end

# … and averaged across the members of an ensemble (skipping missing members).
function _day_bar(ens::Ensemble, doy; window, period)
    triples = [_day_bar(m, doy; window = window, period = period) for m in ens.members]
    avg(field) = begin
        vals = collect(skipmissing(getfield(t, field) for t in triples))
        isempty(vals) ? missing : mean(vals)
    end
    return (lo = avg(:lo), mid = avg(:mid), hi = avg(:hi))
end

# Build the bias-corrected CMIP6 ensemble covering the bias-ref + future span,
# or `nothing` (with a warning) when no projection data can be downloaded.
function _future_ensemble(loc, hist; models, correct, method, bias_ref, future,
                          start::Date)
    isempty(future) && return nothing
    try
        stop = Date(maximum(last(p) for p in future), 12, 31)
        ens = projection_ensemble(loc; models = models, start = start, stop = stop)
        correct && (ens = bias_correct(ens, hist; method = method, ref = bias_ref))
        return ens
    catch err
        @warn "No projection data available; future periods omitted" exception = err
        return nothing
    end
end

"""
    climate_day_comparison(place; date = today(), window = 3, ref, recent, future, ...) -> Figure

Compare today's forecast against the day-of-year temperature climatology across
several eras, as a column of vertical bars. Each bar spans the climatological
`tmin`–`tmax` for `date`'s day-of-year (smoothed over a `±window`-day window),
with a tick at the mean (`tmean`):

- **black** — today's forecast `tmin`–`tmax` (from [`forecast_daily`](@ref)),
- **grey**  — the `ref` reference period (default 1981–2010),
- **`recent`** — the recent observed period (default 2011–2025), from ERA5,
- **`future`** — one bar per future period (default 2041–2050), from a
  bias-corrected CMIP6 ensemble; silently omitted if no projection data is
  available.

Pass `offline = true` (or set the `CLIMSTATS_OFFLINE` environment variable) to
plot only from cached data without any network access; the live forecast bar is
omitted in that case.

```julia
fig = climate_day_comparison("Berlin, Germany")
save("berlin_today_vs_climate.png", fig)
```
"""
climate_day_comparison(place::AbstractString; offline::Bool = offline_mode(), kwargs...) =
    _with_offline(offline) do
        _day_comparison(geocode(place); kwargs...)
    end

"`climate_day_comparison` for an already-resolved [`Location`](@ref) (no geocoding)."
climate_day_comparison(loc::Location; offline::Bool = offline_mode(), kwargs...) =
    _with_offline(offline) do
        _day_comparison(loc; kwargs...)
    end

function _day_comparison(loc::Location;
                                date::Date = Dates.today(),
                                window::Integer = 3,
                                ref::Tuple{Integer,Integer} = (1981, 2010),
                                recent::Tuple{Integer,Integer} = (2011, 2025),
                                future = ((2041, 2050),),
                                models = PROJECTION_MODELS,
                                correct::Bool = true,
                                method::Symbol = :qdm,
                                bias_ref::Tuple{Date,Date} = DEFAULT_REF,
                                forecast::Bool = true,
                                source::Symbol = :power,
                                hist_start::Date = Date(1981, 1, 1))
    doy  = Dates.dayofyear(date)
    hist = history_daily(loc; source = source, start = hist_start, stop = default_stop())

    bars = NamedTuple[]
    if forecast && !offline_mode()
        fc = forecast_daily(loc)
        r  = fc.table[fc.table.date .== date, :]
        nrow(r) == 1 && push!(bars,
            (label = "today", lo = r.tmin[1], mid = r.tmean[1], hi = r.tmax[1],
             color = CP_YEARS[end]))
    end
    rb = _day_bar(hist, doy; window = window, period = ref)
    push!(bars, (label = "$(ref[1])–$(ref[2])", lo = rb.lo, mid = rb.mid,
                 hi = rb.hi, color = "#9aa0a6"))
    cb = _day_bar(hist, doy; window = window, period = recent)
    push!(bars, (label = "$(recent[1])–$(recent[2])", lo = cb.lo, mid = cb.mid,
                 hi = cb.hi, color = CP_YEARS[2]))

    ens = _future_ensemble(loc, hist; models = models, correct = correct,
                           method = method, bias_ref = bias_ref, future = future,
                           start = hist_start)
    if ens !== nothing
        for (i, per) in enumerate(future)
            fb = _day_bar(ens, doy; window = window, period = per)
            push!(bars, (label = "$(per[1])–$(per[2])", lo = fb.lo, mid = fb.mid,
                         hi = fb.hi, color = CP_FUTURE))
        end
    end

    fig = Figure()
    ax = Axis(fig[1, 1];
        ylabel = "temperature (°C)",
        title = @sprintf("%s — temperature on %s  (±%d-day climatology)",
                         _place_label(loc), Dates.format(date, "u d"), window),
        xticks = (1:length(bars), [b.label for b in bars]),
        xticklabelrotation = π / 8)
    w = 0.6
    for (x, b) in enumerate(bars)
        (ismissing(b.lo) || ismissing(b.hi)) && continue
        poly!(ax, Rect(x - w/2, b.lo, w, b.hi - b.lo);
              color = (b.color, 0.35), strokecolor = b.color, strokewidth = 1.5)
        ismissing(b.mid) || lines!(ax, [x - w/2, x + w/2], [b.mid, b.mid];
                                   color = b.color, linewidth = 2.5)
    end
    return fig
end

# Per-month across-member spread of the period climatology, for the future bands.
function _monthly_band(ens::Ensemble, period; var, lo, hi)
    clims = [monthly_climatology(m; var = var, period = period) for m in ens.members]
    lov = fill(NaN, 12); hiv = fill(NaN, 12); med = fill(NaN, 12)
    for mo in 1:12
        vals = Float64[]
        for mc in clims
            r = mc[mc.month .== mo, :mean]
            (isempty(r) || ismissing(r[1])) && continue
            push!(vals, Float64(r[1]))
        end
        isempty(vals) && continue
        lov[mo] = quantile(vals, lo)
        hiv[mo] = quantile(vals, hi)
        med[mo] = median(vals)
    end
    return DataFrame(month = 1:12, lo = lov, median = med, hi = hiv)
end

"""
    climate_monthly(place; var = :tmean, hist_start, future, ...) -> Figure

Seasonal cycle of monthly-mean `var`: every observed year drawn as a faint grey
line, with the most recent complete year and the current (partial) year
highlighted. When projection data is available, each `future` period is added as
a shaded across-model band. Pass `offline = true` (or set `CLIMSTATS_OFFLINE`)
to plot only from cached data without any network access.

```julia
fig = climate_monthly("Berlin, Germany")
save("berlin_monthly_climatology.png", fig)
```
"""
climate_monthly(place::AbstractString; offline::Bool = offline_mode(), kwargs...) =
    _with_offline(offline) do
        _monthly(geocode(place); kwargs...)
    end

"`climate_monthly` for an already-resolved [`Location`](@ref) (no geocoding)."
climate_monthly(loc::Location; offline::Bool = offline_mode(), kwargs...) =
    _with_offline(offline) do
        _monthly(loc; kwargs...)
    end

function _monthly(loc::Location;
                         var::Symbol = :tmean,
                         source::Symbol = :power,
                         hist_start::Date = Date(1981, 1, 1),
                         hist_stop::Date = default_stop(),
                         ref::Tuple{Integer,Integer} = (1991, 2020),
                         recent_years::Integer = 3,
                         future = ((2041, 2050),),
                         models = PROJECTION_MODELS,
                         correct::Bool = true,
                         method::Symbol = :qdm,
                         bias_ref::Tuple{Date,Date} = DEFAULT_REF,
                         lo::Real = 0.1, hi::Real = 0.9)
    hist = history_daily(loc; source = source, start = hist_start, stop = hist_stop)
    mm   = monthly_means(hist; var = var)

    years     = sort(unique(mm.year))
    this_year = maximum(years)

    fig = Figure()
    ax = Axis(fig[1, 1]; xlabel = "month", ylabel = "mean temperature (°C)",
        title = @sprintf("%s — seasonal cycle of %s", _place_label(loc), string(var)),
        xticks = (1:12, _MONTH_ABBR))

    recent = years[max(1, end - recent_years + 1):end]

    # Every year as a faint grey line (the "spaghetti" backdrop), recent ones drawn
    # on top below.
    for y in years
        y in recent && continue
        d = mm[mm.year .== y, :]
        lines!(ax, d.month, _tofloatvec(d.mean); color = CP_SPAGHETTI, linewidth = 0.6)
    end

    # Climatological mean over the reference period, as a dashed grey line.
    refmask = (mm.year .>= ref[1]) .& (mm.year .<= ref[2])
    if any(refmask)
        avg = combine(groupby(mm[refmask, :], :month),
                      :mean => (x -> mean(skipmissing(x))) => :mean)
        sort!(avg, :month)
        lines!(ax, avg.month, _tofloatvec(avg.mean); color = CP_AVERAGE,
               linewidth = 1.4, linestyle = :dash,
               label = @sprintf("%d–%d average", ref[1], ref[2]))
    end

    ens = _future_ensemble(loc, hist; models = models, correct = correct,
                           method = method, bias_ref = bias_ref, future = future,
                           start = hist_start)
    if ens !== nothing
        for per in future
            b = _monthly_band(ens, per; var = var, lo = lo, hi = hi)
            band!(ax, b.month, _tofloatvec(b.lo), _tofloatvec(b.hi);
                  color = (CP_FUTURE, 0.10), label = "$(per[1])–$(per[2])")
            lines!(ax, b.month, _tofloatvec(b.lo); color = (CP_FUTURE, 0.20), linewidth = 0.8)
            lines!(ax, b.month, _tofloatvec(b.hi); color = (CP_FUTURE, 0.20), linewidth = 0.8)
        end
    end

    # The most recent years in warm accents (current year burgundy, on top).
    cols = _recent_year_colors(length(recent))
    for (y, col) in zip(recent, cols)
        d = mm[mm.year .== y, :]
        nrow(d) == 0 && continue
        lbl = y == this_year ? "$(y) (so far)" : string(y)
        scatterlines!(ax, d.month, _tofloatvec(d.mean); color = col,
                      linewidth = 1.4, markersize = 5, label = lbl)
    end
    axislegend(ax; position = :lt, framevisible = false)
    return fig
end

# Per-day-of-year quantile band, pooling the daily `var` of one or more
# ClimateData over a `±window` window and the inclusive year `period`. Used for
# both the observed historical interval ([hist]) and the future ensemble spread
# (the ensemble members). Columns: `:doy`, `:lo`, `:median`, `:hi`.
function _daily_band(datas::Vector{ClimateData}, period; var, window, lo, hi)
    doys = Int[]; vals = Float64[]
    for d in datas
        df = d.table
        hasproperty(df, var) || continue
        w = _restrict_years(DataFrame(date = df.date, v = df[!, var]), period)
        for i in eachindex(w.v)
            ismissing(w.v[i]) && continue
            push!(doys, Dates.dayofyear(w.date[i]))
            push!(vals, Float64(w.v[i]))
        end
    end
    lov = fill(NaN, 366); hiv = fill(NaN, 366); med = fill(NaN, 366)
    for d in 1:366
        pool = Float64[]
        for k in eachindex(doys)
            δ = abs(doys[k] - d); δ = min(δ, 366 - δ)
            δ <= window && push!(pool, vals[k])
        end
        isempty(pool) && continue
        lov[d] = quantile(pool, lo); hiv[d] = quantile(pool, hi); med[d] = median(pool)
    end
    return DataFrame(doy = 1:366, lo = lov, median = med, hi = hiv)
end

"""
    climate_daily(place; var = :tmean, window = 3, ref, future, spaghetti = false, ...) -> Figure

Daily-resolution companion to [`climate_monthly`](@ref): the seasonal cycle of
daily `var` across the year (day-of-year axis), styled after the Copernicus
Climate Pulse charts. Drawn back-to-front:

- with `spaghetti = true` (the default), every available year as a faint
  light-grey line — the "spaghetti" backdrop,
- a magenta band per `future` period from the bias-corrected CMIP6 ensemble
  (omitted if no projection data is available),
- the `ref`-period climatological mean as a dashed grey line (1991–2020 by
  default, smoothed over a `±window`-day window),
- the `recent_years` most recent years as warm accent lines (gold → coral →
  burgundy, current year last), with a marker and label at the current year's
  latest value,
- and, when `forecast = true`, the live forecast mean line.

Pass `offline = true` (or set the `CLIMSTATS_OFFLINE` environment variable) to
plot only from cached data without any network access; the live forecast is
omitted in that case.

```julia
fig = climate_daily("Berlin, Germany"; spaghetti = true)
save("berlin_daily_climatology.png", fig)
```
"""
climate_daily(place::AbstractString; offline::Bool = offline_mode(), kwargs...) =
    _with_offline(offline) do
        _daily(geocode(place); kwargs...)
    end

"`climate_daily` for an already-resolved [`Location`](@ref) (no geocoding)."
climate_daily(loc::Location; offline::Bool = offline_mode(), kwargs...) =
    _with_offline(offline) do
        _daily(loc; kwargs...)
    end

function _daily(loc::Location;
                       var::Symbol = :tmean,
                       window::Integer = 3,
                       ref::Tuple{Integer,Integer} = (1991, 2020),
                       recent_years::Integer = 3,
                       future = ((2041, 2050),),
                       source::Symbol = :power,
                       hist_start::Date = Date(1981, 1, 1),
                       hist_stop::Date = default_stop(),
                       spaghetti::Bool = true,
                       forecast::Bool = true,
                       models = PROJECTION_MODELS,
                       correct::Bool = true,
                       method::Symbol = :qdm,
                       bias_ref::Tuple{Date,Date} = DEFAULT_REF,
                       lo::Real = 0.025, hi::Real = 0.975)
    hist = history_daily(loc; source = source, start = hist_start, stop = hist_stop)
    df   = hist.table
    yr   = Dates.year.(df.date)

    years     = sort(unique(yr))
    this_year = maximum(years)

    fig = Figure()
    ax = Axis(fig[1, 1]; xlabel = "month", ylabel = "$(string(var)) (°C)",
        title = @sprintf("%s — daily %s", _place_label(loc), string(var)),
        xticks = (_MONTH_STARTS, _MONTH_ABBR))

    recent = years[max(1, end - recent_years + 1):end]

    # Every year as a faint grey line — the Climate-Pulse "spaghetti" backdrop.
    if spaghetti
        for y in years
            y in recent && continue
            d = df[yr .== y, :]
            lines!(ax, Dates.dayofyear.(d.date), _tofloatvec(d[!, var]);
                   color = CP_SPAGHETTI, linewidth = 0.5)
        end
    end

    # Future projection band(s) in muted magenta.
    ens = _future_ensemble(loc, hist; models = models, correct = correct,
                           method = method, bias_ref = bias_ref, future = future,
                           start = hist_start)
    if ens !== nothing
        for per in future
            fb = _daily_band(ens.members, per; var = var, window = window,
                             lo = lo, hi = hi)
            band!(ax, fb.doy, _tofloatvec(fb.lo), _tofloatvec(fb.hi);
                  color = (CP_FUTURE, 0.10), label = "$(per[1])–$(per[2])")
            lines!(ax, fb.doy, _tofloatvec(fb.lo); color = (CP_FUTURE, 0.20), linewidth = 0.8)
            lines!(ax, fb.doy, _tofloatvec(fb.hi); color = (CP_FUTURE, 0.20), linewidth = 0.8)
        end
    end

    # Climatological mean over the reference period, as a dashed grey line.
    ab = _daily_band([hist], ref; var = var, window = window, lo = 0.5, hi = 0.5)
    lines!(ax, ab.doy, _tofloatvec(ab.median); color = CP_AVERAGE,
           linewidth = 1.4, linestyle = :dash,
           label = @sprintf("%d–%d average", ref[1], ref[2]))

    # The most recent years in warm accents (current year burgundy, on top).
    cols = _recent_year_colors(length(recent))
    for (y, col) in zip(recent, cols)
        d = df[yr .== y, :]
        nrow(d) == 0 && continue
        lbl = y == this_year ? "$(y) (so far)" : string(y)
        lines!(ax, Dates.dayofyear.(d.date), _tofloatvec(d[!, var]);
               color = col, linewidth = 1.2, label = lbl)
    end

    # Marker at the current year's latest observation, with its date/value label
    # pinned to the top-right corner (axis-relative) so it never overlaps the data.
    dthis = df[yr .== this_year, :]
    valid = findall(!ismissing, dthis[!, var])
    if !isempty(valid)
        k  = last(valid)
        mx = Dates.dayofyear(dthis.date[k]); my = Float64(dthis[k, var])
        scatter!(ax, [mx], [my]; color = CP_YEARS[end], markersize = 9)
        text!(ax, 0.99, 0.99; text = @sprintf("%s  %.2f°C",
              Dates.format(dthis.date[k], "dd u yyyy"), my),
              space = :relative, align = (:right, :top), offset = (-6, -6),
              color = CP_YEARS[end], fontsize = 13)
    end

    if forecast && !offline_mode()
        fc = forecast_daily(loc).table
        x  = Dates.dayofyear.(fc.date)
        band!(ax, x, _tofloatvec(fc.tmin), _tofloatvec(fc.tmax); color = (:black, 0.15))
        lines!(ax, x, _tofloatvec(fc.tmean); color = :black, linewidth = 1.2,
               label = "forecast")
    end

    axislegend(ax; position = :lt, framevisible = false)
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
