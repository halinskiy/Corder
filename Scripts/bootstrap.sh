#!/usr/bin/env bash
# First-time setup. Idempotent: re-running won't clobber existing configs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$HOME/.config/corder"
mkdir -p "$CFG"

copy_if_missing() {
  local src="$1"
  local dst="$2"
  if [[ -e "$dst" ]]; then
    echo "✓ $dst (kept)"
  else
    cp "$src" "$dst"
    chmod 600 "$dst"
    echo "+ $dst (installed from template)"
  fi
}

copy_if_missing "$ROOT/config-templates/dropbox.json.example" "$CFG/dropbox.json"
copy_if_missing "$ROOT/config-templates/gemini_key.example"   "$CFG/gemini_key"

echo
echo "Next steps:"
echo "  1. \$EDITOR $CFG/dropbox.json"
echo "  2. \$EDITOR $CFG/gemini_key"
echo "  3. (optional) install secret-scan hook:  pre-commit install"
echo
echo "Then:  Scripts/build-app.sh && open Corder.app"
