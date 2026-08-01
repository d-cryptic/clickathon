#!/usr/bin/env bash
# Exercise open-session semantics by deriving from a time-truncated raw stream.
# It uses only temporary Memory tables in one ClickHouse client session.
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
  echo "usage: tools/truncation-test.sh ['YYYY-MM-DD HH:MM:SS']" >&2
  exit 2
fi

target=${TARGET:-local}
tail_until=$(TARGET="$target" "$root_dir/tools/ch-run.sh" --query "SELECT formatDateTime(toDateTime('$cutoff', 'UTC') + toIntervalSecond(60), '%F %T') FORMAT TSVRaw")

{
  printf '%s\n' "CREATE TEMPORARY TABLE truncated_raw AS ev_raw ENGINE = Memory;"
  printf '%s\n' "INSERT INTO truncated_raw (content_id, video_session_id, user_id, event_type, event, event_timestamp, platform, app_version, country, audio_language, subtitle_language, player_version, session_start_epoch) SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp, platform, app_version, country, audio_language, subtitle_language, player_version, session_start_epoch FROM ev_raw WHERE event_timestamp <= toDateTime64('$cutoff', 3);"
  printf '%s\n' "CREATE TEMPORARY TABLE truncated_intervals AS session_intervals ENGINE = Memory;"
  printf '%s\n' "CREATE TEMPORARY TABLE truncated_delta AS cc_minute_delta ENGINE = Memory;"
  sed \
    -e 's/INSERT INTO session_intervals/INSERT INTO truncated_intervals/' \
    -e 's/INSERT INTO cc_minute_delta/INSERT INTO truncated_delta/' \
    -e 's/FROM ev_raw/FROM truncated_raw/g' \
    -e 's/FROM session_intervals/FROM truncated_intervals/g' \
    queries/materialize_intervals.sql
  printf '%s\n' "CREATE TEMPORARY TABLE truncated_finalizer_run_log AS finalizer_run_log ENGINE = Memory;"
  printf '%s\n' "CREATE TEMPORARY TABLE truncated_correction_stage AS session_delta_correction_stage ENGINE = Memory;"
  printf '%s\n' "CREATE TEMPORARY TABLE truncated_exact_tail AS exact_tail_minute_stage ENGINE = Memory;"
  printf '%s\n' "INSERT INTO truncated_finalizer_run_log VALUES (toUUID('00000000-0000-0000-0000-000000000001'), 0, 'published', toDateTime64('$cutoff', 3), toDateTime64('$cutoff', 3), toDateTime64('$cutoff', 3), 0, 0, 'state-gated-v1', now64(3));"
  sed \
    -e 's/INSERT INTO exact_tail_minute_stage/INSERT INTO truncated_exact_tail/' \
    -e 's/finalizer_run_log/truncated_finalizer_run_log/g' \
    -e 's/session_delta_correction_stage/truncated_correction_stage/g' \
    -e 's/cc_minute_delta/truncated_delta/g' \
    queries/stage_exact_tail.sql
  printf '%s\n' "WITH toDateTime64('$cutoff', 3) AS cut_at, (SELECT count() FROM truncated_intervals WHERE interval_end > cut_at + toIntervalSecond(60)) AS intervals_beyond_tail_grace, (SELECT count() FROM truncated_intervals WHERE interval_start < cut_at + toIntervalMinute(1) AND interval_end > cut_at) AS expected_tail_concurrency, (SELECT sum(concurrency) FROM truncated_exact_tail WHERE minute = toDateTime('$cutoff', 'UTC')) AS served_tail_concurrency SELECT (SELECT count() FROM truncated_raw) AS truncated_events, (SELECT uniqExact(video_session_id) FROM truncated_intervals WHERE is_open = 1) AS open_sessions, (SELECT count() FROM truncated_intervals WHERE is_open = 1) AS open_intervals, expected_tail_concurrency AS active_at_cutoff_minute, served_tail_concurrency, (SELECT max(dateDiff('second', cut_at, interval_end)) FROM truncated_intervals) AS max_seconds_past_cutoff, intervals_beyond_tail_grace, throwIf(intervals_beyond_tail_grace != 0, 'truncated interval exceeded 60-second tail grace') AS tail_bound_assertion, throwIf(served_tail_concurrency != expected_tail_concurrency, 'exact tail did not absorb open sessions at cutoff') AS tail_absorption_assertion FORMAT PrettyCompact;"
} | TARGET="$target" "$root_dir/tools/ch-run.sh" \
  --multiquery \
  --stdin \
  --param 'run_id=00000000-0000-0000-0000-000000000001' \
  --param 'finalizer_run_sequence=0' \
  --param "event_watermark=$cutoff" \
  --param "tail_until=$tail_until"
