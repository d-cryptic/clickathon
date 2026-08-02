#!/usr/bin/env bash
# Build deck/final/pitch-deck.pdf from deck/final/deck.html via headless Chrome.
# Usage: deck/final/build.sh   (from anywhere; no arguments)
# Requires: Google Chrome. Set CHROME=/path/to/chrome to override autodetection.
set -euo pipefail

cd "$(dirname "$0")"

if [ -z "${CHROME:-}" ]; then
  for c in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
    "$(command -v google-chrome || true)" \
    "$(command -v chromium || true)"; do
    [ -n "$c" ] && [ -f "$c" ] && CHROME="$c" && break
  done
fi
[ -n "${CHROME:-}" ] || { echo "FAIL: Chrome not found; set CHROME=/path/to/chrome"; exit 1; }

# Print the STATIC copy: deck.html's entrance animations start at opacity 0, and
# headless Chrome snapshots t=0, so printing it yields blank/garbled pages.
# deck-static.html freezes every animation at its end state and pins @page to 16:9.
SRC="deck-static.html"
[ -f "$SRC" ] || { echo "FAIL: $SRC missing — regenerate it from deck.html"; exit 1; }

# file:// URL that works on both POSIX and Git-Bash-on-Windows paths
case "$PWD" in
  /c/*|/d/*) URL="file:///$(echo "$PWD" | sed 's|^/\([a-z]\)/|\1:/|')/$SRC" ;;
  *)         URL="file://$PWD/$SRC" ;;
esac

"$CHROME" --headless=new --disable-gpu \
  --no-pdf-header-footer \
  --print-to-pdf="$(pwd -W 2>/dev/null || pwd)/pitch-deck.pdf" \
  "$URL"

# Rules: PDF only, <= 15 slides, <= 20 MB. Verify all three.
pages=$(strings pitch-deck.pdf | grep -c '/Type /Page$' || true)
size=$(stat -f%z pitch-deck.pdf 2>/dev/null || stat -c%s pitch-deck.pdf)
echo "pitch-deck.pdf: ${pages} pages, ${size} bytes"
[ "$pages" -le 15 ] || { echo "FAIL: more than 15 pages"; exit 1; }
[ "$size" -le 20971520 ] || { echo "FAIL: over 20 MB"; exit 1; }
echo "OK: within the 15-slide / 20 MB limits"
