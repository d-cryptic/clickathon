#!/usr/bin/env bash
# Publish an exact snapshot for the newest event-time window. It must follow a
# successful finalizer run: the selected tail is tied to that run sequence so a
# newer correction automatically disables an older tail snapshot.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

usage() {
  echo "usage: tools/refresh-tail.sh [--tail-window-seconds N]" >&2
}

tail_window_s=${TAIL_WINDOW_SECONDS:-900}
requested_model_version=$("$root_dir/tools/model-version.sh")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tail-window-seconds) tail_window_s=${2:?missing value}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if ! [[ "$tail_window_s" =~ ^[0-9]+$ ]] || [ "$tail_window_s" -lt 60 ]; then
  echo "tail window must be an integer of at least 60 seconds" >&2
  exit 2
fi

target=${TARGET:-local}

query() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1"
}

scalar() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1 FORMAT TSVRaw"
}

pending_runs=$(scalar "SELECT count() FROM (SELECT run_id FROM exact_tail_run_log GROUP BY run_id HAVING max(phase) IN ('prepared', 'staged'))")
if [ "$pending_runs" != "0" ]; then
  echo "a tail run is prepared/staged; inspect or abort it before starting another" >&2
  exit 1
fi

finalizer_row=$(scalar "SELECT max(run_sequence), argMax(model_version, run_sequence) FROM finalizer_run_log WHERE phase = 'published'")
IFS=$'\t' read -r finalizer_run_sequence model_version <<< "$finalizer_row"
if [ -z "$finalizer_run_sequence" ]; then
  echo "no published finalizer run; run tools/bootstrap-finalizer.sh --replace first" >&2
  exit 1
fi
if [ "$model_version" != "$requested_model_version" ]; then
  echo "finalizer uses model $model_version, but MODEL_VERSION is $requested_model_version; rebuild the baseline before refreshing the tail" >&2
  exit 1
fi

event_watermark=$(scalar "SELECT formatDateTime(toStartOfMinute(max(event_timestamp) - toIntervalSecond($tail_window_s)), '%F %T') FROM ev_raw")
tail_until=$(scalar "SELECT formatDateTime(toStartOfMinute(max(event_timestamp) + toIntervalSecond(60)), '%F %T') FROM ev_raw")
source_high_watermark=$(scalar "SELECT max(ingested_at) FROM ev_raw")
run_sequence=$(scalar "SELECT max(run_sequence) + 1 FROM exact_tail_run_log")
run_sequence=${run_sequence:-1}
run_id=$(scalar "SELECT generateUUIDv4()")

query "INSERT INTO exact_tail_run_log VALUES (toUUID('$run_id'), $run_sequence, $finalizer_run_sequence, 'prepared', toDateTime('$event_watermark', 'UTC'), toDateTime('$tail_until', 'UTC'), toDateTime64('$source_high_watermark', 3), 0, '$model_version', now64(3))"

TARGET="$target" "$root_dir/tools/ch-run.sh" \
  --multiquery \
  --param "run_id=$run_id" \
  --param "finalizer_run_sequence=$finalizer_run_sequence" \
  --param "event_watermark=$event_watermark" \
  --param "tail_until=$tail_until" \
  --setting "insert_deduplication_token=exact-tail-$run_id" \
  --file queries/stage_exact_tail.sql

staged_rows=$(scalar "SELECT count() FROM exact_tail_minute_stage WHERE run_id = toUUID('$run_id')")
query "INSERT INTO exact_tail_run_log VALUES (toUUID('$run_id'), $run_sequence, $finalizer_run_sequence, 'staged', toDateTime('$event_watermark', 'UTC'), toDateTime('$tail_until', 'UTC'), toDateTime64('$source_high_watermark', 3), $staged_rows, '$model_version', now64(3))"
query "INSERT INTO exact_tail_run_log VALUES (toUUID('$run_id'), $run_sequence, $finalizer_run_sequence, 'published', toDateTime('$event_watermark', 'UTC'), toDateTime('$tail_until', 'UTC'), toDateTime64('$source_high_watermark', 3), $staged_rows, '$model_version', now64(3))"

echo "published exact tail $run_id: $staged_rows active session-minutes, watermark $event_watermark, finalizer sequence $finalizer_run_sequence"
