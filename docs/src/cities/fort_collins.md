# Fort Collins, Colorado

Temperature climatology for **Fort Collins, Colorado**. The historical baseline
(**NASA POWER**, 1981→present) is cached and available:

```julia
using ClimStats
hist = history_daily("Fort Collins, Colorado")   # NASA POWER, offline-ready
monthly_means(hist; var = :tmean)
```

!!! note "Figures pending"
    The CMIP6 projection ensemble for Fort Collins has not been fetched yet (it
    was capped by the Open-Meteo hourly quota during fixture generation), so the
    [`climate_day_comparison`](@ref) / [`climate_monthly`](@ref) /
    [`climate_daily`](@ref) figures — which need the future band — are not shown
    here. They will be added once the ensemble is cached
    (`scripts/generate_fixtures.jl` + `scripts/collect_fixtures.jl`, then
    `docs/make_city_figures.jl`).
