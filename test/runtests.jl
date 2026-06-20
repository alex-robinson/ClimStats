using ClimStats
using ClimStats: _build_table, _tofloat, _daily_param, DAILY_VARMAP
using DataFrames
using Dates
using JSON3
using Plots
using Test

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
    plt = plot_index(days_above(d, 30); title = "test")
    @test plt isa Plots.Plot
    plt2 = plot_index!(plt, annual_mean(d; var = :tmean); valuecol = :mean,
                       label = "mean T")
    @test plt2 isa Plots.Plot
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
