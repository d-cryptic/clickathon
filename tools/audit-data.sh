#!/usr/bin/env bash
# Reproducible data-contract audit. Run after loading any organiser data, before
# choosing a watermark or trusting session-level dimensions.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

cutoff=${1:-2026-07-26 10:30:00}
timestamp_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
if ! [[ "$cutoff" =~ $timestamp_pattern ]]; then
  echo "usage: tools/audit-data.sh ['YYYY-MM-DD HH:MM:SS']" >&2
  exit 2
fi

target=${TARGET:-local}
TARGET="$target" "$root_dir/tools/ch-run.sh" \
  --multiquery \
  --param "cutoff=$cutoff" \
  --file queries/audit_data.sql
