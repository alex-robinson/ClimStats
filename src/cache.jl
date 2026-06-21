# On-disk caching of downloaded point time series, via DataManifest's `@cached`.
#
# The expensive part of this package is the network round trip: every provider
# fetch pulls a daily series for one grid cell over HTTP/OPeNDAP. Those series
# are tiny (~0.4 MB for 76 years of ERA5) but slow to fetch and rate-limited, so
# we content-address them on disk and reload instead of re-downloading.
#
# DataManifest's `@cached` macro keys a result by the SHA-256 of the canonical
# JSON of its hash-affecting parameters, persists it under `datacache_dir`, and
# reloads on identical inputs (with a pidfile lock so parallel dashboard requests
# computing the same cell don't collide). Pass `cache = false` (which the macro
# exposes as `cached = false`) to bypass it entirely.
#
# Two conventions make the cache reusable across calls rather than per-request:
#   * coordinates are snapped to the source grid, so nearby queries that resolve
#     to the same cell share one download (and geocode float-noise can't miss);
#   * the series is stored in a portable Arrow file (cross-language, stable),
#     not Julia's `serialize`, so a future dashboard front-end can read it too.

using DataManifest: @cached
import Arrow
import SHA

# --- codec: a DataFrame <-> Arrow file ------------------------------------

_arrow_save(df, path) = (Arrow.write(path, df); nothing)
_arrow_load(path) = DataFrame(Arrow.Table(path); copycols = true)

# --- content addressing for derived caches ---------------------------------
#
# Derived results (bias-corrected series, nowcast analog completions) depend on
# whole `ClimateData` tables, which are too large to put in a cache key verbatim.
# Instead we digest the data into a single SHA-256 string used as a key field.
# The digest hashes the actual values (not an Arrow byte stream), so it is
# independent of any serialization-format version.

"Stable content digest of a `ClimateData` (source label + every table value)."
function _content_hash(d::ClimateData)
    ctx = SHA.SHA256_CTX()
    SHA.update!(ctx, codeunits(d.source))
    df = d.table
    for c in names(df)
        SHA.update!(ctx, codeunits(c))
        for x in df[!, c]
            if x === missing
                SHA.update!(ctx, UInt8[0xff])
            elseif x isa Date
                SHA.update!(ctx, reinterpret(UInt8, [Int64(Dates.value(x))]))
            elseif x isa Bool
                SHA.update!(ctx, UInt8[x ? 0x01 : 0x00])
            elseif x isa Real
                SHA.update!(ctx, reinterpret(UInt8, [Float64(x)]))
            else
                SHA.update!(ctx, codeunits(string(x)))
            end
        end
    end
    return bytes2hex(SHA.digest!(ctx))
end

# JSON-safe, order-stable renderings of optional/collection key components.
_key_vars(vars) = vars === nothing ? "all" : sort!(string.(collect(vars)))
_key_kinds(kinds) = kinds === nothing ? "default" :
    sort!([string(k) * "=" * string(v) for (k, v) in kinds])
_key_opt(x) = x === nothing ? "auto" : float(x)

# --- keying helpers --------------------------------------------------------

"Snap a coordinate to the source grid (ERA5 and NEX-GDDP are both 0.25°)."
_snap(x; res = 0.25) = round(round(x / res) * res; digits = 6)

# The boundary between the *stable* history (cached) and the recent *tail*
# (fetched live): the last day of the last fully-complete month. Computing it
# from `default_stop()` rather than the caller's requested `stop` means every
# caller shares one stable entry, whose key only rolls forward once a month.
_last_complete_month_end(d::Date) = lastdayofmonth(firstdayofmonth(d) - Day(1))
