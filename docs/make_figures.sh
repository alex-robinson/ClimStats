#!/usr/bin/env bash
# Regenerate the committed documentation figures.
#
#     bash docs/make_figures.sh
#
# The per-location climatology figures and their pages are produced by
# docs/make_locations.jl (offline, from the bundled fixture cache — see
# docs/locations.jl). This wrapper runs that, then renders the one remaining
# figure the locations script does not cover: the current-year nowcast, pinned
# to Berlin and embedded on the nowcast page. The hot-days and SSP tours live in
# the README, not the docs site, so they are not regenerated here.
set -uo pipefail
cd "$(dirname "$0")/.."

ASSETS="docs/src/assets"
mkdir -p "$ASSETS"

# Climatology figures + per-location pages (offline; no network/quota).
julia --project=docs docs/make_locations.jl

# Nowcast figure (Berlin), under a stable name on the nowcast page.
julia --project=. examples/nowcast.jl "Berlin, Germany"
src="examples/berlin_germany_nowcast.png"
if [ -f "$src" ]; then
    cp "$src" "$ASSETS/berlin_hot_days_nowcast.png" && echo "copied $src"
else
    echo "WARNING: $src not produced (skipped)"
fi

echo "Done. Figures in $ASSETS"
