#!/usr/bin/env bash
# Create the per-session baseline required by the live correction finalizer.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ "${1:-}" != "--replace" ]; then
  echo "usage: tools/bootstrap-finalizer.sh --replace [--watermark-lag-seconds N]" >&2
  exit 2
fi
shift

watermark_lag_s=600
model_version=$("$root_dir/tools/model-version.sh")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --watermark-lag-seconds) watermark_lag_s=${2:?missing value}; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$watermark_lag_s" =~ ^[0-9]+$ ]]; then
  echo "watermark lag must be a non-negative number of seconds" >&2
  exit 2
fi

target=${TARGET:-local}

query() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1"
}

scalar() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1 FORMAT TSVRaw"
}

interval_count=$(scalar "SELECT count() FROM session_intervals")
delta_count=$(scalar "SELECT count() FROM cc_minute_delta")
if [ "$interval_count" = "0" ] || [ "$delta_count" = "0" ]; then
  echo "materialize historical intervals and deltas before bootstrapping the finalizer" >&2
  exit 1
fi

source_hwm=$(scalar "SELECT max(ingested_at) FROM ev_raw")
event_watermark=$(scalar "SELECT max(event_timestamp) - toIntervalSecond($watermark_lag_s) FROM ev_raw")

query "TRUNCATE TABLE session_delta_base"
query "TRUNCATE TABLE session_delta_correction_stage"
query "TRUNCATE TABLE finalizer_run_log"

bootstrap_token=$(scalar "SELECT generateUUIDv4()")
TARGET="$target" "$root_dir/tools/ch-run.sh" \
  --multiquery \
  --setting "insert_deduplication_token=bootstrap-$bootstrap_token" \
  --file queries/bootstrap_finalizer_base.sql

mismatches=$(scalar "SELECT count() FROM (SELECT platform, country, content_id, minute FROM (SELECT platform, country, content_id, minute, sum(delta) AS baseline_delta, toInt64(0) AS snapshot_delta FROM cc_minute_delta GROUP BY platform, country, content_id, minute UNION ALL SELECT platform, country, content_id, minute, toInt64(0), sum(delta) FROM session_delta_base GROUP BY platform, country, content_id, minute) GROUP BY platform, country, content_id, minute HAVING sum(baseline_delta) != sum(snapshot_delta))")

if [ "$mismatches" != "0" ]; then
  echo "finalizer bootstrap differs from cc_minute_delta on $mismatches marker(s); refusing checkpoint" >&2
  exit 1
fi

bootstrap_run_id='00000000-0000-0000-0000-000000000000'
base_rows=$(scalar "SELECT count() FROM session_delta_base")
query "INSERT INTO finalizer_run_log VALUES (toUUID('$bootstrap_run_id'), 0, 'published', toDateTime64('$source_hwm', 3), toDateTime64('$source_hwm', 3), toDateTime64('$event_watermark', 3), 0, $base_rows, '$model_version', now64(3))"

echo "bootstrapped finalizer baseline: $base_rows session markers, source high-watermark $source_hwm, model $model_version"
