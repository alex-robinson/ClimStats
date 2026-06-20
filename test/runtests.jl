using ClimStats
using ClimStats: _build_table, _tofloat, _daily_param, DAILY_VARMAP
using DataFrames
using Dates
using JSON3
using Makie
using Statistics
using Test
using ClimStats: _eprob, _quantile_sorted,
    _normalize_scenario, _scenario_for_year, _nexgddp_url, NEXGDDP_VARMAP, NEXGDDP_BASE

# Build a synthetic two-year dataset we can reason about exactly.
function synthetic_data()
    dates = Date(2000, 1, 1):Day(1):Date(2001, 12, 31)
    # tmax: a clean sinusoid peaking mid-summer, amplitude 20 around 12 °C.
    doy = Dates.dayofyear.(dates)
    tmax = 12 .+ 20 .* sin.(2π .* (doy .- 80) ./ 365)
    tmin = tmax .- 8
    tmean = tmax .- 4
    precip = fill(2.0, length(dates))
    df = DataFrame(date = collect(dates),
                   tmax = Vector{Union{Missing,Float64}}(tmax),
                   tmin = Vector{Union{Missing,Float64}}(tmin),
                   tmean = Vector{Union{Missing,Float64}}(tmean),
                   precip = Vector{Union{Missing,Float64}}(precip))
    ClimateData(Location("Testville", "Nowhere", 0.0, 0.0, 0.0), "ERA5", df)
end

@testset "types & accessors" begin
    d = synthetic_data()
    @test d.source == "ERA5"
    @test nrow(table(d)) == 731               # 2000 is a leap year
    @test Set(variables(d)) == Set([:tmax, :tmin, :tmean, :precip])
    @test occursin("Testville", sprint(show, d.location))
    @test occursin("ClimateData", sprint(show, MIME"text/plain"(), d))
end

@testset "annual indices" begin
    d = synthetic_data()

    hot = days_above(d, 30; var = :tmax)
    @test names(hot) == ["year", "days", "n_days"]
    @test sort(hot.year) == [2000, 2001]
    @test all(hot.n_days .== [366, 365])      # leap then non-leap
    @test all(hot.days .> 0)                  # the sinusoid exceeds 30 °C

    # Threshold above the series maximum -> zero days everywhere.
    @test all(days_above(d, 100; var = :tmax).days .== 0)
    # Threshold below the minimum -> every day counts.
    none_below = days_below(d, -100; var = :tmin)
    @test all(none_below.days .== 0)
    all_below = days_below(d, 100; var = :tmin)
    @test all(all_below.days .== all_below.n_days)

    @test all(wet_days(d).days .== [366, 365])   # 2 mm every day ≥ 1 mm
    @test all(annual_sum(d; var = :precip).total .≈ [732.0, 730.0])

    am = annual_mean(d; var = :tmean)
    @test names(am) == ["year", "mean", "n_days"]
    @test all(isfinite, am.mean)
end

@testset "missing handling" begin
    d = synthetic_data()
    d.table[1:5, :tmax] .= missing
    hot = days_above(d, 30; var = :tmax)
    @test hot.n_days[1] == 361                # 366 - 5 missing in year 2000
    @test all(isfinite, annual_mean(d; var = :tmax).mean)
end

@testset "linear_trend" begin
    @test linear_trend([2000, 2001, 2002], [1.0, 2.0, 3.0]).slope ≈ 1.0
    @test linear_trend([2000, 2001, 2002], [1.0, 2.0, 3.0]).intercept ≈ -1999.0
    # Missing values are ignored, not fatal.
    t = linear_trend([2000, 2001, 2002], [1.0, missing, 3.0])
    @test t.slope ≈ 1.0
    @test isnan(linear_trend([2000], [1.0]).slope)
end

@testset "parsing helpers" begin
    @test _tofloat(nothing) === missing
    @test _tofloat(3) === 3.0

    @test _daily_param([:tmax, :precip]) == "temperature_2m_max,precipitation_sum"
    @test_throws ErrorException _daily_param([:not_a_var])

    # Mimic an Open-Meteo `daily` payload, including a null gap.
    payload = JSON3.read("""
    {"time":["2020-01-01","2020-01-02","2020-01-03"],
     "temperature_2m_max":[1.5,null,3.5],
     "precipitation_sum":[0.0,4.0,0.0]}
    """)
    df = _build_table(payload)
    @test df.date == [Date(2020,1,1), Date(2020,1,2), Date(2020,1,3)]
    @test df.tmax[2] === missing
    @test df.tmax[1] == 1.5
    @test df.precip == [0.0, 4.0, 0.0]
    @test !hasproperty(df, :tmin)             # not in payload -> not a column
end

@testset "plotting (smoke)" begin
    d = synthetic_data()
    fig = plot_index(days_above(d, 30); title = "test")
    @test fig isa Figure
    fig2 = plot_index!(fig, annual_mean(d; var = :tmean); valuecol = :mean,
                       label = "mean T")
    @test fig2 isa Figure
    @test ClimStats._axis(fig) isa Axis        # mutating helpers find the axis
end

# Build a dataset over an arbitrary span with a known temperature offset and
# precipitation scaling, so bias correction has an exact answer to recover.
function make_data(years; toffset = 0.0, pscale = 1.0, source = "ERA5")
    dates = Date(first(years), 1, 1):Day(1):Date(last(years), 12, 31)
    doy = Dates.dayofyear.(dates)
    tmax = 12 .+ 20 .* sin.(2π .* (doy .- 80) ./ 365) .+ toffset
    df = DataFrame(date = collect(dates),
                   tmax = Vector{Union{Missing,Float64}}(tmax),
                   tmin = Vector{Union{Missing,Float64}}(tmax .- 8),
                   tmean = Vector{Union{Missing,Float64}}(tmax .- 4),
                   precip = Vector{Union{Missing,Float64}}(fill(2.0 * pscale, length(dates))))
    ClimateData(Location("T", "N", 0.0, 0.0, 0.0), source, df)
end

@testset "bias correction" begin
    ref = (Date(2000, 1, 1), Date(2010, 12, 31))
    obs   = make_data(2000:2010)
    model = make_data(2000:2010; toffset = 3.0, pscale = 2.0, source = "ModelX")

    bc = fit_bias_correction(obs, model; ref = ref)
    @test bc.kinds[:tmax] == :additive
    @test bc.kinds[:precip] == :multiplicative
    @test all(≈(-3.0), values(bc.adjust[:tmax]))   # remove the +3 °C offset
    @test all(≈(0.5),  values(bc.adjust[:precip]))  # undo the ×2 precip

    corr = apply_bias_correction(model, bc)
    @test occursin("bias-corrected", corr.source)
    @test all(isapprox.(corr.table.tmax, obs.table.tmax; atol = 1e-6))
    @test all(isapprox.(corr.table.precip, obs.table.precip; atol = 1e-6))
    # Corrected model reproduces the observed index exactly.
    @test days_above(corr, 30).days == days_above(obs, 30).days
    # One-shot helper agrees with the two-step path.
    @test bias_correct(model, obs; ref = ref).table.tmax == corr.table.tmax
end

# Minimal ClimateData with a single temperature column on given dates.
cd_tmax(dates, t; source = "ERA5") =
    ClimateData(Location("T", "N", 0.0, 0.0, 0.0), source,
                DataFrame(date = collect(dates),
                          tmax = Vector{Union{Missing,Float64}}(t)))

@testset "quantile mapping helpers" begin
    s = Float64[1, 2, 3, 4, 5]
    @test _quantile_sorted(s, 0.0) == 1.0
    @test _quantile_sorted(s, 1.0) == 5.0
    @test _quantile_sorted(s, 0.5) == 3.0          # median
    @test 0.0 <= _eprob(s, 3.0) <= 1.0
    @test _eprob(s, -100.0) < _eprob(s, 100.0)     # monotone in x
    @test _eprob(s, 3.0) ≈ 0.5 atol = 0.11         # middle value ~ median rank
end

@testset "quantile mapping correction" begin
    dates = Date(2000, 1, 1):Day(1):Date(2009, 12, 31)
    doy = Dates.dayofyear.(dates)
    # seasonal cycle + an 11-day component so months have real internal spread
    base = 12 .+ 20 .* sin.(2π .* (doy .- 80) ./ 365) .+ 5 .* sin.(2π .* doy ./ 11)
    ref = (first(dates), last(dates))

    # (a) pure additive shift: QM should recover the observed distribution.
    obs   = cd_tmax(dates, base)
    model = cd_tmax(dates, base .+ 3.0; source = "M")
    for m in (:qdm, :eqm)
        corr = bias_correct(model, obs; method = m, ref = ref)
        @test occursin(string(m), corr.source)
        cv = Float64.(corr.table.tmax); ov = Float64.(obs.table.tmax)
        @test abs(mean(cv) - mean(ov)) < 0.2
        for q in (0.1, 0.5, 0.9)
            @test abs(quantile(cv, q) - quantile(ov, q)) < 0.3
        end
    end

    # (b) inflated variance + bias: QM corrects the spread, delta does not.
    infl = mean(base) .+ 1.8 .* (base .- mean(base)) .+ 2.0
    obs2   = cd_tmax(dates, base)
    model2 = cd_tmax(dates, infl; source = "M")
    qdm   = bias_correct(model2, obs2; method = :qdm,   ref = ref)
    delta = bias_correct(model2, obs2; method = :delta, ref = ref)
    sobs = std(Float64.(obs2.table.tmax))
    err_qdm   = abs(std(Float64.(qdm.table.tmax))   - sobs)
    err_delta = abs(std(Float64.(delta.table.tmax)) - sobs)
    @test err_qdm < err_delta                       # QM fixes distribution shape

    # (c) multiplicative QM on precipitation recovers the observed mean.
    pobs = 1.0 .+ Float64.(doy .% 5)
    obsP = ClimateData(Location("T", "N", 0, 0, 0), "ERA5",
                       DataFrame(date = collect(dates),
                                 precip = Vector{Union{Missing,Float64}}(pobs)))
    modP = ClimateData(Location("T", "N", 0, 0, 0), "M",
                       DataFrame(date = collect(dates),
                                 precip = Vector{Union{Missing,Float64}}(2 .* pobs)))
    corrP = bias_correct(modP, obsP; method = :qdm, ref = ref)
    @test all(corrP.table.precip .>= 0)
    @test abs(mean(corrP.table.precip) - mean(obsP.table.precip)) < 0.2
end

@testset "ensemble" begin
    loc = Location("T", "N", 0.0, 0.0, 0.0)
    m1 = make_data(2000:2010; toffset = 1.0, source = "A")
    m2 = make_data(2000:2010; toffset = 2.0, source = "B")
    ens = Ensemble(loc, [m1, m2], ["A", "B"])

    summ = ensemble_index(ens, d -> days_above(d, 30))
    @test names(summ) == ["year", "lo", "median", "hi", "mean", "n"]
    @test all(summ.n .== 2)
    @test issorted(summ.year)
    @test all(summ.lo .<= summ.median .<= summ.hi)
    # Warmer member has at least as many hot days as the cooler one.
    @test all(summ.hi .>= summ.lo)

    @test bias_correct(ens, m1).members[1].source == "A (bias-corrected)"

    fig = plot_index(days_above(m1, 30); label = "A")
    @test plot_ensemble!(fig, summ; label = "ens") isa Figure
end

@testset "NEX-GDDP / SSP logic" begin
    # historical/SSP routing splits at 2014
    @test _scenario_for_year(2000, "ssp245") == "historical"
    @test _scenario_for_year(2014, "ssp245") == "historical"
    @test _scenario_for_year(2015, "ssp245") == "ssp245"

    # scenario normalisation + labels
    @test _normalize_scenario(:ssp245) == "ssp245"
    @test _normalize_scenario("SSP585") == "ssp585"
    @test_throws ArgumentError _normalize_scenario(:ssp999)
    @test scenario_label(:ssp126) == "SSP1-2.6"
    @test scenario_label(:ssp585) == "SSP5-8.5"
    @test Set(SSP_SCENARIOS) == Set([:ssp126, :ssp245, :ssp370, :ssp585])

    # model registry: defaults and overrides
    @test nexgddp_model_spec("ACCESS-CM2") == ("r1i1p1f1", "gn")
    @test nexgddp_model_spec("GFDL-ESM4") == ("r1i1p1f1", "gr1")
    @test nexgddp_model_spec("ACCESS-CM2"; grid = "gr") == ("r1i1p1f1", "gr")
    @test nexgddp_model_spec("Unknown-Model") == ("r1i1p1f1", "gn")

    # unit conversions: K -> °C, kg m⁻² s⁻¹ -> mm/day
    @test NEXGDDP_VARMAP.tmax[1] == "tasmax"
    @test NEXGDDP_VARMAP.tmax[2](273.15) ≈ 0.0
    @test NEXGDDP_VARMAP.precip[2](1.0) ≈ 86400.0

    # OPeNDAP URL construction
    url = _nexgddp_url(NEXGDDP_BASE, "ACCESS-CM2", "ssp245",
                       "r1i1p1f1", "gn", "tasmax", 2050)
    @test endswith(url,
        "ACCESS-CM2/ssp245/r1i1p1f1/tasmax/tasmax_day_ACCESS-CM2_ssp245_r1i1p1f1_gn_2050.nc")

    # without NCDatasets loaded, the backend errors helpfully (not a MethodError)
    loc = Location("T", "N", 52.5, 13.4, 0.0)
    err = try
        nexgddp_daily(loc); nothing
    catch e
        e
    end
    @test err isa ErrorException && occursin("NCDatasets", err.msg)
    @test_throws ErrorException ssp_ensemble(loc; models = ["ACCESS-CM2"])
end

# Network-dependent tests only run when explicitly enabled, because CI / the
# build sandbox usually has no outbound internet access.
if get(ENV, "CLIMSTATS_NETWORK_TESTS", "false") == "true"
    @testset "live Open-Meteo" begin
        loc = geocode("Berlin, Germany")
        @test occursin("Berlin", loc.name)
        @test 52 < loc.latitude < 53
        data = era5_daily(loc; start = Date(2020,1,1), stop = Date(2020,12,31))
        @test nrow(table(data)) == 366
        @test all(days_above(data, 30).days .>= 0)
    end
end
