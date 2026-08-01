#!/usr/bin/env bash
# Raw-to-serving correctness gate for the state-gated historical spine.
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

result=$(TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --file queries/reconcile.sql)

printf '%s\n' "$result"

if printf '%s\n' "$result" | grep -q 'FAIL'; then
  echo "raw-to-serving reconciliation failed" >&2
  exit 1
fi
