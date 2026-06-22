#!/usr/bin/env bash
# Regenerate the committed documentation figures from the (general) example
# scripts, pinned to one location (Berlin), and copy them under docs/src/assets/
# where the documentation pages reference them. The example scripts themselves
# take the place as an argument; this wrapper is just the docs-specific pinning.
#
#     bash docs/make_figures.sh
#
# Needs internet access (Open-Meteo). The hot-days and SSP tours live in the
# README, not the docs site, so they are not regenerated here (SSP also needs the
# NetCDF stack and reachable NASA NCCS).
set -uo pipefail
cd "$(dirname "$0")/.."

PLACE="Berlin, Germany"
SLUG="berlin_germany"
ASSETS="docs/src/assets"
mkdir -p "$ASSETS"

julia --project=. examples/climatology.jl "$PLACE"
julia --project=. examples/nowcast.jl     "$PLACE"

copy() {  # copy <example-name> <asset-name>
    local src="examples/${SLUG}_$1.png"
    if [ -f "$src" ]; then
        cp "$src" "$ASSETS/$2" && echo "copied $src -> $ASSETS/$2"
    else
        echo "WARNING: $src not produced (skipped)"
    fi
}

# Climatology figures keep their (slugged) names; the nowcast figure is embedded
# under a stable name on the nowcast page.
copy today_vs_climate    berlin_germany_today_vs_climate.png
copy monthly_climatology berlin_germany_monthly_climatology.png
copy daily_climatology   berlin_germany_daily_climatology.png
copy nowcast             berlin_hot_days_nowcast.png

echo "Done. Figures in $ASSETS"
