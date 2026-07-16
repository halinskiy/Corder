#!/usr/bin/env bash
# Build the PUBLIC share page (share.getcorder.com) into Web/dist-share/.
#
# Separate from build-app.sh on purpose: that one bundles the in-app frontend
# into the .app, this one produces a static site. They share the component
# source and nothing else.
#
# This script is for checking the build locally. The real deploy runs the same
# two commands on Vercel via `Web/vercel.json` (buildCommand + outputDirectory),
# so deploy from `Web/`, never from `dist-share/`: vite's `emptyOutDir` wipes
# the output dir on every build, which would take the `.vercel` project link
# with it and silently create a NEW project on the next deploy.
#
#   cd Web && vercel deploy --prod
set -euo pipefail

cd "$(dirname "$0")/.."
cd Web

npx tsc --noEmit
npx vite build --config vite.share.config.ts

# Vercel serves a directory root, so the entry must be index.html. Vite names
# the output after its input (share.html); rename rather than duplicate.
mv dist-share/share.html dist-share/index.html

echo "✔ Built Web/dist-share (deploy: cd Web && vercel deploy --prod)"
