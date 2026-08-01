#!/usr/bin/env bash
# Recompute only sessions touched since the last source checkpoint. Corrections
# are complete target states and become query-visible only after publication.
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
  echo "usage: tools/finalize.sh [--watermark-lag-seconds N] [--overlap-seconds N] [--resume RUN_UUID]" >&2
}

watermark_lag_s=600
overlap_s=900
resume_run_id=''
requested_model_version=$("$root_dir/tools/model-version.sh")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --watermark-lag-seconds) watermark_lag_s=${2:?missing value}; shift 2 ;;
    --overlap-seconds) overlap_s=${2:?missing value}; shift 2 ;;
    --resume) resume_run_id=${2:?missing value}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if ! [[ "$watermark_lag_s" =~ ^[0-9]+$ ]] || ! [[ "$overlap_s" =~ ^[0-9]+$ ]]; then
  echo "watermark lag and overlap must be non-negative numbers of seconds" >&2
  exit 2
fi

target=${TARGET:-local}
# This is a portable same-host guard only. ADR 0014 requires a distributed,
# externally fenced lease before more than one scheduler can reach this target.
source "$root_dir/tools/finalizer-lock.sh"
case "$target" in
  local) lock_identity="${CH_CONTAINER:-ch}.${CH_DATABASE:-default}" ;;
  cloud) lock_identity="${CH_HOST:?CH_HOST must be set for TARGET=cloud}.${CH_DATABASE:-default}" ;;
  *) echo "TARGET must be local or cloud" >&2; exit 2 ;;
esac
finalizer_lock_acquire "$target" "$lock_identity"

query() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1"
}

scalar() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" --query "$1 FORMAT TSVRaw"
}

run_stage() {
  TARGET="$target" "$root_dir/tools/ch-run.sh" \
    --multiquery \
    --param "run_id=$run_id" \
    --param "run_sequence=$run_sequence" \
    --param "source_from=$source_from" \
    --param "source_high_watermark=$source_high_watermark" \
    --setting "insert_deduplication_token=finalizer-$run_id" \
    --file queries/stage_finalizer_corrections.sql
}

pending_runs=$(scalar "SELECT count() FROM (SELECT run_id FROM finalizer_run_log GROUP BY run_id HAVING max(phase) IN ('prepared', 'staged'))")

if [ -n "$resume_run_id" ]; then
  state=$(scalar "SELECT max(phase) FROM finalizer_run_log WHERE run_id = toUUID('$resume_run_id')")
  if [ -z "$state" ]; then
    echo "run $resume_run_id does not exist" >&2
    exit 1
  fi
  if [ "$state" = "published" ] || [ "$state" = "aborted" ]; then
    echo "run $resume_run_id is already $state" >&2
    exit 1
  fi

  resume_row=$(scalar "SELECT run_sequence, source_from, source_high_watermark, event_watermark, affected_sessions, model_version FROM finalizer_run_log WHERE run_id = toUUID('$resume_run_id') AND phase = 'prepared' ORDER BY recorded_at ASC LIMIT 1")
  IFS=$'\t' read -r run_sequence source_from source_high_watermark event_watermark affected_sessions model_version <<< "$resume_row"
  if [ "$model_version" != "$requested_model_version" ]; then
    echo "run $resume_run_id uses model $model_version, but MODEL_VERSION is $requested_model_version; resume with its original model or rebuild the baseline" >&2
    exit 1
  fi
  case "$state" in
    prepared)
      # A crash can leave a partial, invisible stage. Never rerun it under the
      # same sequence: future rows for a touched session would make argMax tie.
      query "INSERT INTO finalizer_run_log VALUES (toUUID('$resume_run_id'), $run_sequence, 'aborted', toDateTime64('$source_from', 3), toDateTime64('$source_high_watermark', 3), toDateTime64('$event_watermark', 3), $affected_sessions, 0, '$model_version', now64(3))"
      echo "aborted prepared run $resume_run_id without restaging; rerun tools/finalize.sh to create a fresh sequence" >&2
      exit 1
      ;;
    staged)
      recorded_staged_rows=$(scalar "SELECT staged_rows FROM finalizer_run_log WHERE run_id = toUUID('$resume_run_id') AND phase = 'staged' ORDER BY recorded_at DESC LIMIT 1")
      actual_staged_rows=$(scalar "SELECT count() FROM session_delta_correction_stage WHERE run_id = toUUID('$resume_run_id')")
      if [ "$recorded_staged_rows" != "$actual_staged_rows" ]; then
        query "INSERT INTO finalizer_run_log VALUES (toUUID('$resume_run_id'), $run_sequence, 'aborted', toDateTime64('$source_from', 3), toDateTime64('$source_high_watermark', 3), toDateTime64('$event_watermark', 3), $affected_sessions, $actual_staged_rows, '$model_version', now64(3))"
        echo "aborted staged run $resume_run_id: recorded $recorded_staged_rows markers but found $actual_staged_rows" >&2
        exit 1
      fi
      query "INSERT INTO finalizer_run_log VALUES (toUUID('$resume_run_id'), $run_sequence, 'published', toDateTime64('$source_from', 3), toDateTime64('$source_high_watermark', 3), toDateTime64('$event_watermark', 3), $affected_sessions, $actual_staged_rows, '$model_version', now64(3))"
      echo "published resumed finalizer run $resume_run_id: $affected_sessions sessions, $actual_staged_rows correction markers, event watermark $event_watermark, model $model_version"
      exit 0
      ;;
    *)
      echo "run $resume_run_id has unsupported resumable state $state" >&2
      exit 1
      ;;
  esac
else
  if [ "$pending_runs" != "0" ]; then
    echo "a finalizer run is prepared/staged; resume it explicitly before starting another" >&2
    exit 1
  fi

  # The finalizer uses video_session_id as its state key. Recheck the source
  # contract before allocating a visible run so a live admission violation
  # cannot be silently merged into an existing lifecycle.
  TARGET="$target" "$root_dir/tools/validate-source-contract.sh"

  source_high_watermark=$(scalar "SELECT max(ingested_at) FROM ev_raw")
  checkpoint_row=$(scalar "SELECT argMax(source_high_watermark, run_sequence), max(run_sequence) + 1, argMax(model_version, run_sequence) FROM finalizer_run_log WHERE phase = 'published'")
  IFS=$'\t' read -r previous_hwm run_sequence model_version <<< "$checkpoint_row"
  if [ -z "$previous_hwm" ]; then
    echo "no bootstrap checkpoint; run tools/bootstrap-finalizer.sh --replace first" >&2
    exit 1
  fi
  if [ "$model_version" != "$requested_model_version" ]; then
    echo "baseline uses model $model_version, but MODEL_VERSION is $requested_model_version; rebuild with tools/materialize.sh --replace then tools/bootstrap-finalizer.sh --replace" >&2
    exit 1
  fi

  source_from=$(scalar "SELECT toDateTime64('$previous_hwm', 3) - toIntervalSecond($overlap_s)")
  event_watermark=$(scalar "SELECT max(event_timestamp) - toIntervalSecond($watermark_lag_s) FROM ev_raw WHERE ingested_at <= toDateTime64('$source_high_watermark', 3)")
  affected_sessions=$(scalar "SELECT uniqExact(video_session_id) FROM ev_raw WHERE ingested_at >= toDateTime64('$source_from', 3) AND ingested_at <= toDateTime64('$source_high_watermark', 3)")
  run_id=$(scalar "SELECT generateUUIDv4()")

  query "INSERT INTO finalizer_run_log VALUES (toUUID('$run_id'), $run_sequence, 'prepared', toDateTime64('$source_from', 3), toDateTime64('$source_high_watermark', 3), toDateTime64('$event_watermark', 3), $affected_sessions, 0, '$model_version', now64(3))"
fi

run_stage
staged_rows=$(scalar "SELECT count() FROM session_delta_correction_stage WHERE run_id = toUUID('$run_id')")
query "INSERT INTO finalizer_run_log VALUES (toUUID('$run_id'), $run_sequence, 'staged', toDateTime64('$source_from', 3), toDateTime64('$source_high_watermark', 3), toDateTime64('$event_watermark', 3), $affected_sessions, $staged_rows, '$model_version', now64(3))"
query "INSERT INTO finalizer_run_log VALUES (toUUID('$run_id'), $run_sequence, 'published', toDateTime64('$source_from', 3), toDateTime64('$source_high_watermark', 3), toDateTime64('$event_watermark', 3), $affected_sessions, $staged_rows, '$model_version', now64(3))"

echo "published finalizer run $run_id: $affected_sessions sessions, $staged_rows correction markers, event watermark $event_watermark, model $model_version"
