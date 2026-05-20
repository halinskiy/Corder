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
# Deliberately NOT installing a gemini_key placeholder. An un-edited
# "<paste-…>" file used to read as a real key and fail with a confusing
# Gemini 400; with NO file the app shows the clean "configure your key"
# path (and the Library UI can set it). Create it with your real key.
if [ ! -e "$CFG/gemini_key" ]; then
  echo "· $CFG/gemini_key (NOT created — add your real Gemini key here)"
else
  echo "✓ $CFG/gemini_key (kept)"
fi

echo
echo "Next steps:"
echo "  1. \$EDITOR $CFG/dropbox.json"
echo "  2. echo 'YOUR_GEMINI_KEY' > $CFG/gemini_key   (or set it in the app's Library UI)"
echo "  3. (optional) install secret-scan hook:  pre-commit install"
echo
echo "Then:  Scripts/build-app.sh && open Corder.app"
