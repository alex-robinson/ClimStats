# NASA NEX-GDDP-CMIP6 backend: SSP-scenario climate projections.
#
# NEX-GDDP-CMIP6 is a daily, statistically downscaled (0.25°) CMIP6 dataset
# covering historical (1950–2014) and four SSP scenarios (2015–2100):
# ssp126, ssp245, ssp370, ssp585. NASA NCCS serves it over OPeNDAP, one NetCDF
# file per model / scenario / variable / year, which lets us pull a single
# grid-cell time series without downloading the global field.
#
# This file holds the *pure* logic — scenario handling, URL construction, unit
# conversion, the model registry and the high-level ensemble/plot helpers — all
# of which are unit-tested offline. The actual NetCDF reads live in the optional
# package extension `ext/ClimStatsNCDatasetsExt.jl`, loaded by `using NCDatasets`,
# so the heavy NetCDF/HDF5 stack stays out of the core ERA5 path.

"OPeNDAP root for the NASA NCCS NEX-GDDP-CMIP6 archive."
const NEXGDDP_BASE = "https://ds.nccs.nasa.gov/thredds/dodsC/AMES/NEX/GDDP-CMIP6"

"The four SSP scenarios available in NEX-GDDP-CMIP6."
const SSP_SCENARIOS = (:ssp126, :ssp245, :ssp370, :ssp585)

# ClimStats column => (NEX-GDDP variable name, converter from native units).
# Temperatures are stored in kelvin; precipitation flux in kg m⁻² s⁻¹.
const NEXGDDP_VARMAP = (
    tmax   = ("tasmax", x -> x - 273.15),    # K -> °C
    tmin   = ("tasmin", x -> x - 273.15),
    tmean  = ("tas",    x -> x - 273.15),
    precip = ("pr",     x -> x * 86400.0),   # kg m⁻² s⁻¹ -> mm/day
)

# Per-model variant/grid labels. Most NEX-GDDP models are r1i1p1f1 on a native
# "gn" grid; the exceptions below are common ones. Anything not listed falls
# back to the r1i1p1f1/gn default, and both can be overridden per call.
const _NEXGDDP_SPEC = Dict{String,Tuple{String,String}}(
    "GFDL-CM4"         => ("r1i1p1f1", "gr1"),
    "GFDL-ESM4"        => ("r1i1p1f1", "gr1"),
    "GFDL-CM4_gr2"     => ("r1i1p1f1", "gr2"),
    "EC-Earth3"        => ("r1i1p1f1", "gr"),
    "EC-Earth3-Veg-LR" => ("r1i1p1f1", "gr"),
    "KACE-1-0-G"       => ("r1i1p1f1", "gr"),
    "CNRM-CM6-1"       => ("r1i1p1f2", "gr"),
    "CNRM-ESM2-1"      => ("r1i1p1f2", "gr"),
    "MIROC-ES2L"       => ("r1i1p1f2", "gn"),
    "UKESM1-0-LL"      => ("r1i1p1f2", "gn"),
)

"A broad set of NEX-GDDP-CMIP6 models known to be available."
const NEXGDDP_MODELS = [
    "ACCESS-CM2", "ACCESS-ESM1-5", "BCC-CSM2-MR", "CMCC-CM2-SR5", "CMCC-ESM2",
    "EC-Earth3", "EC-Earth3-Veg-LR", "GFDL-CM4", "GFDL-ESM4", "INM-CM4-8",
    "INM-CM5-0", "KACE-1-0-G", "MIROC6", "MPI-ESM1-2-HR", "MPI-ESM1-2-LR",
    "MRI-ESM2-0", "NorESM2-LM", "NorESM2-MM", "TaiESM1",
]

"A small, fast default ensemble (all r1i1p1f1 / gn) for the SSP helpers."
const NEXGDDP_DEFAULT_MODELS = [
    "ACCESS-CM2", "MPI-ESM1-2-HR", "MRI-ESM2-0", "NorESM2-MM", "CMCC-ESM2",
]

"""
    nexgddp_model_spec(model; variant = nothing, grid = nothing) -> (variant, grid)

Resolve the realisation `variant` and `grid` labels for a NEX-GDDP `model`,
applying the built-in registry and any explicit overrides.
"""
function nexgddp_model_spec(model::AbstractString; variant = nothing, grid = nothing)
    dv, dg = get(_NEXGDDP_SPEC, model, ("r1i1p1f1", "gn"))
    return (variant === nothing ? dv : String(variant),
            grid === nothing ? dg : String(grid))
end

"Normalise an SSP scenario (Symbol or String) to a validated lowercase string."
function _normalize_scenario(s)
    sym = Symbol(lowercase(String(s)))
    sym in SSP_SCENARIOS ||
        throw(ArgumentError("Unknown SSP scenario $(repr(s)); choose from $(SSP_SCENARIOS)."))
    return String(sym)
end

"""
    scenario_label(s) -> String

Human-readable label for an SSP scenario, e.g. `:ssp126 -> "SSP1-2.6"`.
"""
function scenario_label(s)
    str = _normalize_scenario(s)
    return Dict("ssp126" => "SSP1-2.6", "ssp245" => "SSP2-4.5",
                "ssp370" => "SSP3-7.0", "ssp585" => "SSP5-8.5")[str]
end

# NEX-GDDP splits at 2014: years up to and including 2014 are "historical",
# later years use the chosen SSP. This lets one call return a continuous series.
_scenario_for_year(year::Integer, ssp::AbstractString) =
    year <= 2014 ? "historical" : ssp

"""
    _nexgddp_url(base, model, scenario, variant, grid, nexvar, year; version = "") -> String

Build the OPeNDAP URL for a single NEX-GDDP file. `version` allows the data-
version suffix some files carry (e.g. `"_v1.1"`).
"""
function _nexgddp_url(base, model, scenario, variant, grid, nexvar, year; version = "")
    fname = "$(nexvar)_day_$(model)_$(scenario)_$(variant)_$(grid)_$(year)$(version).nc"
    return "$(base)/$(model)/$(scenario)/$(variant)/$(nexvar)/$(fname)"
end

# --- backend entry point (real method provided by the NCDatasets extension) ---

"""
    nexgddp_daily(place; scenario = :ssp245, model = "ACCESS-CM2", kwargs...) -> ClimateData

Download a daily NEX-GDDP-CMIP6 point time series for `place` (a string or
[`Location`](@ref)), splicing historical and the chosen SSP into one continuous
series. Returns the same [`ClimateData`](@ref) shape as [`era5_daily`](@ref), so
every index, bias-correction and plotting helper works on it unchanged.

Keyword arguments
- `scenario` : one of `$(SSP_SCENARIOS)`.
- `model`    : a NEX-GDDP model name (see [`NEXGDDP_MODELS`](@ref)).
- `variant` / `grid` : override the realisation/grid labels if needed.
- `start` / `stop`   : date range (default 1950-01-01 … 2100-12-31).
- `vars`     : variables to fetch (default all of `$(keys(NEXGDDP_VARMAP))`).

!!! note
    This requires the NetCDF stack. Run `using NCDatasets` once to enable it
    (NCDatasets is an optional dependency, loaded via a package extension).
"""
function nexgddp_daily(args...; kwargs...)
    throw(ErrorException(
        "nexgddp_daily requires NCDatasets.jl. Add it (`] add NCDatasets`) and " *
        "run `using NCDatasets` to enable the NEX-GDDP-CMIP6 backend."))
end

# --- high-level SSP helpers (backend-agnostic) ------------------------------

"""
    ssp_ensemble(place; scenario = :ssp245, models = NEXGDDP_DEFAULT_MODELS, kwargs...) -> Ensemble

Build a NEX-GDDP projection [`Ensemble`](@ref) for one SSP scenario, one member
per model. Models that fail to load are skipped with a warning. `kwargs` go to
[`nexgddp_daily`](@ref).
"""
function ssp_ensemble(place; scenario = :ssp245,
                      models = NEXGDDP_DEFAULT_MODELS, kwargs...)
    loc = place isa Location ? place : geocode(place)
    scen = _normalize_scenario(scenario)
    members = ClimateData[]
    used = String[]
    for m in models
        try
            push!(members, nexgddp_daily(loc; scenario = scen, model = m, kwargs...))
            push!(used, m)
        catch err
            @warn "Skipping NEX-GDDP model $m ($scen)" exception = err
        end
    end
    isempty(members) && error("No NEX-GDDP models could be loaded for $loc ($scen).")
    return Ensemble(loc, members, used)
end

"""
    climate_ssp(place; scenarios, threshold, var, index, models, correct, method, ...) -> Plot

The SSP headline figure: ERA5 history plus a bias-corrected NEX-GDDP ensemble for
each SSP scenario on one set of axes, every scenario drawn as a median line with
a shaded spread band, out to 2100.

```julia
plt = climate_ssp("Berlin, Germany"; threshold = 30,
                  scenarios = (:ssp126, :ssp245, :ssp585))
savefig(plt, "berlin_hot_days_ssp.png")
```

Keyword arguments mirror [`climate_projection`](@ref), plus `scenarios` (the SSPs
to draw). `vars` defaults to just the index variable to keep downloads small;
pass it explicitly for a custom `index` that needs more.
"""
function climate_ssp(place::AbstractString;
                     scenarios = (:ssp126, :ssp245, :ssp585),
                     threshold::Real = 30,
                     var::Symbol = :tmax,
                     index = nothing,
                     models = NEXGDDP_DEFAULT_MODELS,
                     correct::Bool = true,
                     method::Symbol = :qdm,
                     ref::Tuple{Date,Date} = DEFAULT_REF,
                     hist_start::Date = Date(1950, 1, 1),
                     hist_stop::Date = default_stop(),
                     proj_start::Date = Date(1950, 1, 1),
                     proj_stop::Date = Date(2100, 12, 31),
                     vars = index === nothing ? (var,) : keys(NEXGDDP_VARMAP),
                     band::Bool = true,
                     kwargs...)
    loc  = geocode(place)
    hist = era5_daily(loc; start = hist_start, stop = hist_stop)
    indexfn = index === nothing ? (d -> days_above(d, threshold; var = var)) : index
    hist_idx = indexfn(hist)
    vc = _default_valuecol(hist_idx)

    place_lbl = isempty(loc.country) ? loc.name : "$(loc.name), $(loc.country)"
    title = index === nothing ?
        @sprintf("%s — days/yr with %s > %g°C\nERA5 + NEX-GDDP-CMIP6 by SSP",
                 place_lbl, string(var), float(threshold)) :
        "$(place_lbl)\nERA5 + NEX-GDDP-CMIP6 by SSP"
    ylabel = index === nothing ? "days per year" : string(vc)

    plt = plot_index(hist_idx; valuecol = vc, label = "ERA5", title = title,
                     ylabel = ylabel, trend = false, color = 1, kwargs...)
    for (k, scen) in enumerate(scenarios)
        ens = ssp_ensemble(loc; scenario = scen, models = models,
                           start = proj_start, stop = proj_stop, vars = vars)
        correct && (ens = bias_correct(ens, hist; method = method, ref = ref))
        summary = ensemble_index(ens, indexfn; valuecol = vc)
        plot_ensemble!(plt, summary; label = scenario_label(scen),
                       band = band, color = k + 1)
    end
    return plt
end
