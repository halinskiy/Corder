#!/usr/bin/env python3
"""Extract one version's entry from CHANGELOG.md and emit HTML release notes.

Sparkle's `generate_appcast` embeds a `<description>` for an update ONLY when a
notes file (`.html`/`.md`/`.txt`) sits next to the archive with the SAME base
name (e.g. `Corder-0.14.61.html` beside `Corder-0.14.61.zip`). Without it the
in-app modal shows "No release notes attached to this update." This script is
the single source of those notes: it reads the canonical CHANGELOG and writes
the per-version HTML so the appcast is never empty again.

Output is intentionally plain `<ul><li>` HTML (no DOCTYPE/body) so
generate_appcast wraps it as CDATA, and BOTH downstream cleaners
(`CorderUpdateDriver.htmlToPlain` on the Swift side, `cleanNotes` in
UpdateModal.tsx on the web side) render it as tight plain-text lines.

Usage: changelog-to-notes.py <version> <changelog-path>   (prints HTML to stdout)
"""
import html
import re
import sys


def extract(version: str, changelog: str) -> list[str]:
    """Return the bullet items under `## [<version>]`, joining continuations."""
    lines = changelog.splitlines()
    # Find the heading line for this exact version: `## [0.14.61], date`.
    start = None
    head_re = re.compile(r"^##\s*\[" + re.escape(version) + r"\]")
    for i, ln in enumerate(lines):
        if head_re.match(ln):
            start = i + 1
            break
    if start is None:
        return []

    bullets: list[str] = []
    for ln in lines[start:]:
        if ln.startswith("## "):  # next version section, stop
            break
        stripped = ln.strip()
        if not stripped:
            continue
        if stripped.startswith("###"):  # Added / Changed / Fixed sub-headers, skip
            continue
        if stripped.startswith("- "):
            bullets.append(stripped[2:].strip())
        elif bullets and (ln.startswith("  ") or ln.startswith("\t")):
            # Indented continuation of the previous bullet (the CHANGELOG
            # wraps long entries across several indented lines).
            bullets[-1] += " " + stripped
    return bullets


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: changelog-to-notes.py <version> <changelog-path>\n")
        return 2
    version, path = sys.argv[1], sys.argv[2]
    with open(path, "r", encoding="utf-8") as fh:
        bullets = extract(version, fh.read())
    if not bullets:
        sys.stderr.write(f"changelog-to-notes: no entry for {version}\n")
        return 1
    items = "\n".join(f"<li>{html.escape(b)}</li>" for b in bullets)
    sys.stdout.write(f"<ul>\n{items}\n</ul>\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
