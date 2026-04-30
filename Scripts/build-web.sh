#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Web"
npm install --no-audit --no-fund
npm run build
rm -rf "$ROOT/Sources/Corder/Resources/web"
mkdir -p "$ROOT/Sources/Corder/Resources/web"
cp -R dist/. "$ROOT/Sources/Corder/Resources/web/"
echo "✔ Web bundle copied into SwiftPM resources"
