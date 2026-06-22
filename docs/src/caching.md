# Caching

Downloading is the slow, rate-limited part of working with point climate data,
so ClimStats caches both what it **fetches** and what it **derives**. Caching is
on by default, transparent, and persists across sessions: the second time you ask
for a location, it comes from disk.

It is built on [DataManifest.jl](https://github.com/awi-esc/DataManifest.jl)'s
content-addressed `@cached` store. Each cache entry is keyed by the SHA-256 of
the *meaning* of a call (not by a filename) and stored as a portable
[Arrow](https://arrow.apache.org) file, so the cache can even be shared with a
Python or JavaScript front-end.

## What is cached

| Layer                      | Function(s)                                        | Keyed by |
|----------------------------|----------------------------------------------------|----------|
| ERA5 point series          | [`era5_daily`](@ref)                               | snapped cell + stable month |
| CMIP6 projection series    | [`projection_daily`](@ref)                         | snapped cell + model |
| NEX-GDDP point series      | [`nexgddp_daily`](@ref)                            | snapped cell + model/scenario/variant/grid/variable |
| Bias-corrected series      | [`bias_correct`](@ref)                             | content of both inputs + fit parameters |
| Nowcast analog completions | [`complete_current_year`](@ref), [`estimate_current_year`](@ref) | content of `data` + analog settings |

## Why it reuses rather than re-fetches

Three design choices turn the cache from a per-request scratchpad into a genuine
"fetch once" store:

1. **Coordinates snap to the 0.25° source grid.** Two nearby queries — or the
   same place geocoded twice with floating-point noise — resolve to the same grid
   cell and therefore share one cached download.

2. **One download serves many queries.** [`era5_daily`](@ref) caches the full
   history `[1950 … last complete month]` *once per cell* (all four variables);
   any later call, at any date range or variable subset, is sliced from it. Only
   the recent, still-changing tail is fetched live each time. The stable cache
   key rolls forward once a month — which is also when finalised ERA5 replaces the
   preliminary ERA5T values at the edge, so the cache self-heals rather than
   freezing stale data. NEX-GDDP is a fixed archive, so its full 1950–2100 span
   is cached once per cell and never re-read.

3. **Derived results skip recompute, not just re-download.** The expensive,
   *index-independent* steps — the quantile-mapping fit in
   [`bias_correct`](@ref) and the analog resampling behind the nowcast — are
   cached as their intermediates. Running ten different indices over one location
   recomputes nothing; only the cheap index application runs live. This is why the
   nowcast caches the completed analog members (and their weights) rather than any
   single index's estimate.

## Controlling the cache

Every cached function takes `cache = true` by default. Pass `cache = false` to
bypass the cache and force a fresh computation:

```julia
era5_daily("Berlin, Germany"; cache = false)              # re-download
bias_correct(model, hist; method = :qdm, cache = false)   # re-fit
estimate_current_year(data, d -> days_above(d, 30); cache = false)
```

Entries live under the per-project user cache directory:

- **macOS:** `~/Library/Caches/datamanifest/projects/ClimStats/cached/`
- **Linux:** `$XDG_CACHE_HOME/datamanifest/projects/ClimStats/cached/`
  (default `~/.cache/...`)

Each entry directory holds the `data.arrow` payload alongside a `config.toml`
recording the key that produced it. Deleting a directory simply forces that one
result to be recomputed on next use.

For a deployed dashboard, point DataManifest's `datacache_dir` at a shared,
persistent volume so every instance reuses a single cache.

## API

```@docs
era5_daily
projection_daily
nexgddp_daily
bias_correct
```
