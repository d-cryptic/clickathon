#!/usr/bin/env bash
# Build the derived model from ev_raw. Deliberately explicit: this is the safe
# historical backfill path, not the bounded finalizer used for the live tail.
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

query() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1"
}

scalar() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1 FORMAT TSVRaw"
}

if [ "${1:-}" != "--replace" ]; then
  echo "usage: tools/materialize.sh --replace" >&2
  echo "refusing to replace derived tables without an explicit flag" >&2
  exit 2
fi

raw_events=$(scalar "SELECT count() FROM ev_raw")
if ! [[ "$raw_events" =~ ^[0-9]+$ ]] || [ "$raw_events" = "0" ]; then
  echo "ev_raw is empty or unreadable on TARGET=$target; refusing to truncate the derived model" >&2
  exit 1
fi
echo "raw events on TARGET=$target: $raw_events"
"$root_dir/tools/validate-source-contract.sh"
query "TRUNCATE TABLE session_intervals"
query "TRUNCATE TABLE cc_minute_delta"
# A historical rebuild changes the baseline that corrections are relative to.
# Do not leave a published overlay from the prior baseline query-visible.
query "TRUNCATE TABLE IF EXISTS session_delta_base"
query "TRUNCATE TABLE IF EXISTS session_delta_correction_stage"
query "TRUNCATE TABLE IF EXISTS finalizer_run_log"
query "TRUNCATE TABLE IF EXISTS exact_tail_minute_stage"
query "TRUNCATE TABLE IF EXISTS exact_tail_run_log"

TARGET="$target" "$root_dir/tools/ch-run.sh" --multiquery --file queries/materialize_intervals.sql

query "SELECT 'session_intervals' AS table, count() AS rows FROM session_intervals UNION ALL SELECT 'cc_minute_delta', count() FROM cc_minute_delta FORMAT PrettyCompact"
