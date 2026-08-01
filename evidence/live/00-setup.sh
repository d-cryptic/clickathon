#!/usr/bin/env bash
# ============================================================================
# 00-setup.sh — build a gate-green FINAL model in a scratch database.
#
# Everything in evidence/live/ measures the difference between what the serving
# layer believes AT A CUT TIME T and what it believes once the whole stream has
# landed. That needs a trustworthy "final" to diff against, and the graded
# database cannot supply one: as of 2026-08-02 it fails its own reconcile gate
# and serves three tier vintages (evidence/query-robustness/README.md F1). So we
# build our own from the raw events and prove it green before trusting it.
#
# `sonyliv` is read with SELECT only, for ev_raw, and is never written. The guard
# below greps THIS FILE for writes to it and refuses to run if it finds one.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRATCH="${SCRATCH_DB:-sonyliv_v3live}"

# ── refuse to run if this script can write the graded database ───────────────
# Matches `sonyliv` as a whole word only, so `sonyliv_v3live` is not a hit.
if grep -nEi '(INSERT[[:space:]]+INTO|TRUNCATE([[:space:]]+TABLE)?|ALTER[[:space:]]+TABLE|DROP[[:space:]]+(TABLE|DATABASE)|OPTIMIZE[[:space:]]+TABLE|CREATE[[:space:]]+(TABLE|DATABASE))[[:space:]]+sonyliv([^_A-Za-z0-9]|$)' "$0"; then
  echo "REFUSING: this script contains a write against the graded database." >&2
  exit 1
fi
[ "$SCRATCH" = sonyliv ] && { echo "REFUSING: SCRATCH_DB is the graded database." >&2; exit 1; }

q()  { CH_DATABASE="$SCRATCH" tools/ch -c "$1"; }

echo "=== LIVE-INTERVAL EVIDENCE · setup"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "scratch database: $SCRATCH   ·   sonyliv read-only (SELECT on ev_raw only)"
echo

echo "PHASE 0 — reset the scratch database"
CH_DATABASE=default tools/ch -c "DROP DATABASE IF EXISTS $SCRATCH"
CH_DATABASE=default tools/ch -c "CREATE DATABASE $SCRATCH"
TARGET=cloud tools/apply-sql.sh --database "$SCRATCH" \
    sql/00_schema.sql sql/10_intervals.sql sql/20_views.sql >/dev/null
echo "  schema applied from sql/00_schema.sql, sql/10_intervals.sql, sql/20_views.sql"

echo
echo "PHASE 1 — copy the raw stream (13 canonical columns; graded ev_raw has a"
echo "          drifted 14th, ingested_at, which is deliberately not carried)"
q "INSERT INTO $SCRATCH.ev_raw
    (content_id, video_session_id, user_id, event_type, event, event_timestamp,
     platform, app_version, country, audio_language, subtitle_language,
     player_version, session_start_epoch)
   SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
     platform, app_version, country, audio_language, subtitle_language,
     player_version, session_start_epoch
   FROM sonyliv.ev_raw"
printf '  events/sessions/first/last: '
q "SELECT count(), uniqExact(video_session_id), min(event_timestamp), max(event_timestamp)
   FROM $SCRATCH.ev_raw FORMAT TSV"

echo
echo "PHASE 2 — the FINAL model: sql/30_build_intervals.sql then sql/40_deltas.sql"
q "$(cat sql/30_build_intervals.sql)"
q "$(cat sql/40_deltas.sql)"
printf '  intervals / open rows / sessions: '
q "SELECT count(), sum(is_open), uniqExact(video_session_id)
   FROM $SCRATCH.session_intervals FINAL FORMAT TSV"
printf '  delta rows / peak / peak minute:  '
q "SELECT (SELECT count() FROM $SCRATCH.cc_minute_delta),
         (SELECT max(concurrent) FROM $SCRATCH.v_concurrency_minute_delta_total),
         (SELECT argMax(minute, concurrent) FROM $SCRATCH.v_concurrency_minute_delta_total)
   FORMAT TSV"

echo
echo "PHASE 3 — the gate. sql/90_reconcile.sql recomputes concurrency from ev_raw"
echo "          with an INDEPENDENT implementation and compares to the served tier."
q "$(cat sql/90_reconcile.sql)"

echo
echo "PHASE 4 — cross-check: interval EXPANSION must equal the served DELTA curve."
echo "          The sweep in 10-asof-sweep.sh counts by expansion, so this is what"
echo "          licenses reading its output as 'what the dashboard would serve'."
q "WITH exp AS (
     SELECT toDateTime(m) AS minute, uniqExact(video_session_id) AS concurrent
     FROM (SELECT video_session_id,
                  arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                                  toUInt32(toStartOfMinute(interval_end))+1, 60)) AS m
           FROM $SCRATCH.session_intervals FINAL)
     GROUP BY minute)
   SELECT 'minutes_compared=' || toString(count())
       || '  mismatched=' || toString(countIf(e.concurrent != d.concurrent))
       || '  max_abs_diff=' || toString(max(abs(toInt64(e.concurrent) - toInt64(d.concurrent))))
       || if(countIf(e.concurrent != d.concurrent) = 0, '  PASS', '  FAIL')
   FROM exp e INNER JOIN $SCRATCH.v_concurrency_minute_delta_total d USING (minute)
   FORMAT TSVRaw"

echo
echo "setup done."
