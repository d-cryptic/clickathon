#!/usr/bin/env bash
# ============================================================================
# 10-asof-sweep.sh — what did the serving layer believe AT time T?
#
# For each cut T we re-run the REAL derivation (sql/30_build_intervals.sql,
# templated only to add `WHERE event_timestamp < T`) over the prefix of the
# stream visible at T. That build is what a live dashboard would have been
# serving at T — open sessions and all. We then diff it, minute by minute,
# against the final build from 00-setup.sh.
#
# WHY EXPANSION AND NOT THE DELTA VIEW. Concurrency is counted here by expanding
# intervals over a DENSE minute spine (uniqExact sessions covering the minute).
# `v_concurrency_minute_delta_total` is deliberately SPARSE — it emits a row only
# for minutes where some session opens or closes (1,579 minutes vs the 3,732 a
# session actually covers), and a reader carries the running sum across the gaps.
# Diffing two sparse curves would silently score every carried minute as absent.
# Expansion is dense by construction and 00-setup.sh PHASE 4 proves it equals the
# served delta curve on every minute the delta tier emits.
#
# `sonyliv` is never read or written here — everything runs off the scratch copy.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRATCH="${SCRATCH_DB:-sonyliv_v3live}"

if grep -nEi '(INSERT[[:space:]]+INTO|TRUNCATE([[:space:]]+TABLE)?|ALTER[[:space:]]+TABLE|DROP[[:space:]]+(TABLE|DATABASE)|OPTIMIZE[[:space:]]+TABLE|CREATE[[:space:]]+(TABLE|DATABASE))[[:space:]]+sonyliv([^_A-Za-z0-9]|$)' "$0"; then
  echo "REFUSING: this script contains a write against the graded database." >&2
  exit 1
fi
[ "$SCRATCH" = sonyliv ] && { echo "REFUSING: SCRATCH_DB is the graded database." >&2; exit 1; }

q() { CH_DATABASE="$SCRATCH" tools/ch -c "$1"; }

echo "=== LIVE-INTERVAL EVIDENCE · as-of-T sweep"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ)   ·   scratch database: $SCRATCH"
echo

# ---------------------------------------------------------------------------
# Tables. asof_intervals holds every cut's derivation, tagged by cut.
# ---------------------------------------------------------------------------
q "DROP TABLE IF EXISTS $SCRATCH.asof_intervals"
q "DROP TABLE IF EXISTS $SCRATCH.asof_curve"
q "CREATE TABLE $SCRATCH.asof_intervals
   (cut DateTime, video_session_id String, user_id String, content_id Int64,
    platform LowCardinality(String), country LowCardinality(String),
    app_version LowCardinality(String), audio_language LowCardinality(String),
    subtitle_language LowCardinality(String), player_version LowCardinality(String),
    interval_start DateTime64(3), interval_end DateTime64(3),
    is_open UInt8, build_version UInt64)
   ENGINE = MergeTree ORDER BY (cut, video_session_id, interval_start)
   SETTINGS min_bytes_for_wide_part = 0"
q "CREATE TABLE $SCRATCH.asof_curve
   (cut DateTime, minute DateTime, asof UInt64, open_asof UInt64,
    final UInt64, diff Int64, age_s Int64)
   ENGINE = MergeTree ORDER BY (cut, minute)
   SETTINGS min_bytes_for_wide_part = 0"

# ---------------------------------------------------------------------------
# The cut list: every 5 minutes across the whole live event, from the quiet
# pre-show through the ramp, the peak and the decay, plus 10:56 (the peak
# minute itself, and the cut evidence/truncation.txt already used).
# ---------------------------------------------------------------------------
CUTS=$(q "SELECT toString(toDateTime('2026-07-26 09:00:00') + INTERVAL number * 5 MINUTE)
          FROM numbers(31)
          UNION ALL SELECT '2026-07-26 10:56:00'
          ORDER BY 1 FORMAT TSV" | sort -u)
NCUTS=$(echo "$CUTS" | grep -c .)
echo "cuts: $NCUTS  (5-minute grid 09:00→11:30, plus the 10:56 peak minute)"

# The real derivation, with two surgical edits: drop the INSERT header (lines
# 70-73) so the body becomes a SELECT, and bound the source to the prefix.
# Nothing else is touched — the tunables, the pause algebra, the dimension
# attribution and the is_open rule are the shipped ones.
derivation_body() {
  sed '70,73d' sql/30_build_intervals.sql \
    | sed "s|^        FROM ev_raw\$|        FROM ev_raw WHERE event_timestamp < toDateTime64('$1',3)|" \
    | sed 's/;[[:space:]]*$//'
}

# `$CUTS` is newline-separated 'YYYY-MM-DD HH:MM:SS', so it must be read a line
# at a time — word-splitting would cut each timestamp in half at the space.
echo "$CUTS" | while IFS= read -r T; do
  [ -n "$T" ] || continue
  q "INSERT INTO $SCRATCH.asof_intervals
       (cut, video_session_id, user_id, content_id, platform, country, app_version,
        audio_language, subtitle_language, player_version, interval_start,
        interval_end, is_open, build_version)
     SELECT toDateTime('$T') AS cut, * FROM ( $(derivation_body "$T") )"
  printf '.'
done
echo

printf 'derivations stored: '
q "SELECT toString(uniqExact(cut)) || ' cuts, ' || toString(count()) || ' intervals'
   FROM $SCRATCH.asof_intervals FORMAT TSVRaw"

# ---------------------------------------------------------------------------
# The curve. Dense spine over the whole stream, restricted per cut to minutes
# at or before that cut — a live dashboard cannot be asked about the future.
# `open_asof` counts the sessions contributing to that minute that were STILL
# OPEN at the cut (no VideoSessionEnd seen yet), i.e. the provisional share.
# ---------------------------------------------------------------------------
echo "building the per-cut curve against a dense minute spine ..."
q "INSERT INTO $SCRATCH.asof_curve (cut, minute, asof, open_asof, final, diff, age_s)
   WITH
     bounds AS (SELECT toUInt32(toStartOfMinute(min(event_timestamp))) AS m0,
                       toUInt32(toStartOfMinute(max(event_timestamp))) AS m1
                FROM $SCRATCH.ev_raw),
     -- numbers() takes a plain numeric, and a scalar subquery arrives as
     -- Nullable(Int64) — hence the assumeNotNull/toUInt64 rather than the bare
     -- subquery, which fails with ILLEGAL_TYPE_OF_ARGUMENT.
     spine AS (SELECT toDateTime(assumeNotNull((SELECT m0 FROM bounds)) + number * 60) AS minute
               FROM numbers(toUInt64(assumeNotNull((SELECT intDiv(m1 - m0, 60) + 2 FROM bounds))))),
     cuts AS (SELECT DISTINCT cut FROM $SCRATCH.asof_intervals),
     asof_agg AS (
       SELECT cut, toDateTime(m) AS minute,
              uniqExact(video_session_id)                  AS asof,
              uniqExactIf(video_session_id, is_open = 1)   AS open_asof
       FROM (SELECT cut, video_session_id, is_open,
                    arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                                    toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
             FROM $SCRATCH.asof_intervals)
       GROUP BY cut, minute),
     final_agg AS (
       SELECT toDateTime(m) AS minute, uniqExact(video_session_id) AS final
       FROM (SELECT video_session_id,
                    arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                                    toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
             FROM $SCRATCH.session_intervals FINAL)
       GROUP BY minute)
   SELECT c.cut, s.minute,
          ifNull(a.asof, 0)       AS asof,
          ifNull(a.open_asof, 0)  AS open_asof,
          ifNull(f.final, 0)      AS final,
          toInt64(ifNull(a.asof, 0)) - toInt64(ifNull(f.final, 0)) AS diff,
          toInt64(c.cut) - toInt64(s.minute)                       AS age_s
   FROM cuts c
   CROSS JOIN spine s
   LEFT JOIN asof_agg  a ON a.cut = c.cut AND a.minute = s.minute
   LEFT JOIN final_agg f ON f.minute = s.minute
   WHERE s.minute <= c.cut"

printf 'curve rows: '
q "SELECT toString(count()) FROM $SCRATCH.asof_curve FORMAT TSVRaw"

echo
echo "sweep done."
