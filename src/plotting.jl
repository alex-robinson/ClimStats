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
