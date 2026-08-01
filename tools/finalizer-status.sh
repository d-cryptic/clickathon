#!/usr/bin/env bash
# Report the checkpoint and correction overlay that determine served freshness.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

target=${TARGET:-local}
TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --file queries/finalizer_status.sql
