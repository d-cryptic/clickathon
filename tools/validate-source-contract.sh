#!/usr/bin/env bash
# Fail before materialization when this source cannot be safely interpreted by
# the current state machine. Retried payloads and terminal duplicates remain
# observable warnings; they are explicitly handled by the derivation.
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
TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --file queries/validate_source_contract.sql
