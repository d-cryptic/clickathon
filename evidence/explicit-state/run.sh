#!/usr/bin/env bash
# evidence/explicit-state/run.sh — build every explicit-state variant in the
# scratch DB exs_q12 (local only; the graded sonyliv is never touched) and
# print the gate-semantics headline metrics per variant.
# Usage: run.sh [variant ...]   (default: all generated sql/*.sql)
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
CH="$ROOT/tools/ch"
DB=exs_q12

DDL='(
    `video_session_id` String, `user_id` String, `content_id` Int64,
    `platform` LowCardinality(String), `country` LowCardinality(String),
    `app_version` LowCardinality(String), `audio_language` LowCardinality(String),
    `subtitle_language` LowCardinality(String), `player_version` LowCardinality(String),
    `interval_start` DateTime64(3), `interval_end` DateTime64(3),
    `is_open` UInt8, `build_version` UInt64
) ENGINE = MergeTree ORDER BY (video_session_id, interval_start)'

"$CH" "CREATE DATABASE IF NOT EXISTS $DB"

variants=("$@")
if [ ${#variants[@]} -eq 0 ]; then
  variants=()
  for f in sql/*.sql; do variants+=("$(basename "$f" .sql)"); done
fi

for v in "${variants[@]}"; do
  "$CH" "DROP TABLE IF EXISTS $DB.si_$v"
  "$CH" "CREATE TABLE $DB.si_$v $DDL"
  "$CH" "$(cat "sql/$v.sql")"
  # Headline metrics with the gate's own expansion semantics
  # (90_reconcile.sql truth_min: inclusive minute range, uniqExact sessions).
  metrics=$("$CH" "
    WITH per_min AS (
      SELECT m, uniqExact(video_session_id) AS c
      FROM (SELECT video_session_id,
                   arrayJoin(range(intDiv(toUnixTimestamp(interval_start),60)*60,
                                   intDiv(toUnixTimestamp(interval_end),60)*60 + 1, 60)) AS m
            FROM $DB.si_$v)
      GROUP BY m)
    SELECT
      (SELECT count() FROM $DB.si_$v),
      (SELECT round(sum(dateDiff('second', interval_start, interval_end))/3600, 1) FROM $DB.si_$v),
      max(c), toDateTime(argMax(m, c))
    FROM per_min
    FORMAT TSV")
  printf '%-22s %s\n' "$v" "$metrics"
done
