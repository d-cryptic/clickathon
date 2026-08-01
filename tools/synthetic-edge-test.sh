#!/usr/bin/env bash
# Deterministic adversarial event-stream suite. It runs the production SQL over
# temporary Memory tables, so it verifies the state machine without durable IO.
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$root_dir"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

container_name=${CH_CONTAINER:-ch}
password=${CH_PASSWORD_LOCAL:?CH_PASSWORD_LOCAL must be set in .env or the environment}

{
  printf '%s\n' "CREATE TEMPORARY TABLE synthetic_raw AS ev_raw ENGINE = Memory;"
  printf '%s\n' "INSERT INTO synthetic_raw (content_id, video_session_id, user_id, event_type, event, event_timestamp, platform, app_version, country, audio_language, subtitle_language, player_version, session_start_epoch) VALUES
    (1, 'edge-bg', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (1, 'edge-bg', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (1, 'edge-bg', 'u', 'AppBackgrounded', 'AppBackgrounded', '2026-01-01 10:00:30.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (1, 'edge-bg', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:40.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (1, 'edge-bg', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:01:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (1, 'edge-bg', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:01:10.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (2, 'edge-pause', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (2, 'edge-pause', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (2, 'edge-pause', 'u', 'VideoHeartbeat', 'pause', '2026-01-01 10:00:30.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (2, 'edge-pause', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:40.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (2, 'edge-pause', 'u', 'VideoHeartbeat', 'resume', '2026-01-01 10:01:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (2, 'edge-pause', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:01:10.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (3, 'edge-dim', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (3, 'edge-dim', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:40.000', 'B', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (3, 'edge-dim', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (4, 'edge-error', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (4, 'edge-error', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (4, 'edge-error', 'u', 'VideoError', 'VideoError', '2026-01-01 10:00:30.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (4, 'edge-error', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:40.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (5, 'edge-duplicate', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (5, 'edge-duplicate', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (5, 'edge-duplicate', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (6, 'edge-unmatched-bg', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (6, 'edge-unmatched-bg', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (6, 'edge-unmatched-bg', 'u', 'AppBackgrounded', 'AppBackgrounded', '2026-01-01 10:00:30.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (6, 'edge-unmatched-bg', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:40.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (999, 'edge-stop', 'u', 'AppForegrounded', 'AppForegrounded', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (999, 'edge-stop', 'u', 'VideoHeartbeat', 'heartbeat', '2026-01-01 10:00:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000'),
    (999, 'edge-stop', 'u', 'AppBackgrounded', 'AppBackgrounded', '2026-01-01 10:01:00.000', 'A', 'v', 'IN', '', '', 'p', '2026-01-01 10:00:00.000');"
  printf '%s\n' "CREATE TEMPORARY TABLE synthetic_intervals AS session_intervals ENGINE = Memory;"
  printf '%s\n' "CREATE TEMPORARY TABLE synthetic_delta AS cc_minute_delta ENGINE = Memory;"
  sed \
    -e 's/INSERT INTO session_intervals/INSERT INTO synthetic_intervals/' \
    -e 's/INSERT INTO cc_minute_delta/INSERT INTO synthetic_delta/' \
    -e 's/FROM ev_raw/FROM synthetic_raw/g' \
    -e 's/FROM session_intervals/FROM synthetic_intervals/g' \
    queries/materialize_intervals.sql
  printf '%s\n' "WITH checks AS (SELECT 'background_gate' AS name, (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-bg') = 2 AS passed UNION ALL SELECT 'pause_gate', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-pause') = 2 UNION ALL SELECT 'dimension_handoff', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-dim') = 2 AND (SELECT max(interval_end) FROM synthetic_intervals WHERE video_session_id = 'edge-dim' AND platform = 'A') = toDateTime64('2026-01-01 10:00:40.000', 3) UNION ALL SELECT 'error_is_nonterminal', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-error') = 1 AND (SELECT max(interval_end) FROM synthetic_intervals WHERE video_session_id = 'edge-error') = toDateTime64('2026-01-01 10:01:40.000', 3) UNION ALL SELECT 'exact_duplicate_dedup', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-duplicate') = 1 UNION ALL SELECT 'exact_minute_stop', (SELECT sum(delta) FROM synthetic_delta WHERE content_id = 999 AND minute = toDateTime('2026-01-01 10:01:00')) = -1) SELECT name, passed FROM checks ORDER BY name; SELECT throwIf(countIf(NOT passed) != 0, 'synthetic foreground state-machine regression') FROM (WITH checks AS (SELECT 'background_gate' AS name, (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-bg') = 2 AS passed UNION ALL SELECT 'pause_gate', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-pause') = 2 UNION ALL SELECT 'dimension_handoff', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-dim') = 2 AND (SELECT max(interval_end) FROM synthetic_intervals WHERE video_session_id = 'edge-dim' AND platform = 'A') = toDateTime64('2026-01-01 10:00:40.000', 3) UNION ALL SELECT 'error_is_nonterminal', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-error') = 1 AND (SELECT max(interval_end) FROM synthetic_intervals WHERE video_session_id = 'edge-error') = toDateTime64('2026-01-01 10:01:40.000', 3) UNION ALL SELECT 'exact_duplicate_dedup', (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-duplicate') = 1 UNION ALL SELECT 'exact_minute_stop', (SELECT sum(delta) FROM synthetic_delta WHERE content_id = 999 AND minute = toDateTime('2026-01-01 10:01:00')) = -1) SELECT * FROM checks);"
  printf '%s\n' "SELECT 'unmatched_background_fails_closed' AS name, (SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-unmatched-bg') = 1 AND (SELECT max(interval_end) FROM synthetic_intervals WHERE video_session_id = 'edge-unmatched-bg') = toDateTime64('2026-01-01 10:00:30.000', 3) AS passed; SELECT throwIf((SELECT count() FROM synthetic_intervals WHERE video_session_id = 'edge-unmatched-bg') != 1 OR (SELECT max(interval_end) FROM synthetic_intervals WHERE video_session_id = 'edge-unmatched-bg') != toDateTime64('2026-01-01 10:00:30.000', 3), 'unmatched background must fail closed');"
} | docker exec -i "$container_name" clickhouse-client --user app --password "$password" --multiquery
