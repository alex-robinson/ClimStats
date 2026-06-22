using Documenter
using ClimStats

include("locations.jl")

makedocs(;
    modules = [ClimStats],
    sitename = "ClimStats",
    authors = "alex-robinson",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://alex-robinson.github.io/ClimStats",
        edit_link = "main",
        # `logo.svg` is auto-detected for the sidebar; the `.ico` asset sets the
        # browser favicon (a simplified version of the same warming-stripes mark).
        assets = ["assets/favicon.ico"],
    ),
    pages = [
        "Home" => "index.md",
        "Caching" => "caching.md",
        "Climatology" => "climatology.md",
        "Current-year nowcast" => "nowcast.md",
        "Locations" => [loc.place => "cities/$(loc.slug).md" for loc in DOC_LOCATIONS],
    ],
    # These docs are scoped to the nowcast, so docstrings here cross-reference
    # core symbols (ClimateData, …) that aren't documented on a page; let those
    # render as text rather than failing the build. Figures are pre-rendered
    # (they need live Open-Meteo access) and committed under src/assets/, so the
    # build itself stays offline.
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(;
    repo = "github.com/alex-robinson/ClimStats.git",
    devbranch = "main",
    push_preview = true,
)
