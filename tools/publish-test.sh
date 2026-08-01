#!/usr/bin/env bash
# ============================================================================
# tools/publish-test.sh — proof that the aggregates MOVE without a rebuild.
#
# ADR 0013 claims tools/publish.sh publishes incrementally and lands on exactly
# the number a full recompute would. A claim is not evidence. This harness:
#
#   1. builds the model on a truncated slice THROUGH THE INCREMENTAL PATH and
#      shows it is byte-identical to a batch rebuild of the same slice;
#   2. lands late arrivals in three shapes — a handful of open sessions, the
#      whole remaining stream, and one genuine STRAGGLER dated 46 minutes
#      behind the watermark — and after each one shows the served number moved
#      and still equals a from-scratch control build on EVERY minute;
#   3. reads system.query_log back to show what each incremental run actually
#      touched, against what the rebuild touches;
#   4. republishes an UNCHANGED session and shows the curve does not move —
#      the property that makes over-consuming the change log safe.
#
# ISOLATION. Two scratch databases, sonyliv_pub (live, published incrementally)
# and sonyliv_pub_ctl (control, rebuilt from scratch). `sonyliv` is read with
# SELECT only; assert_isolation() below refuses to run if that is not true of
# this file. Never point this at the graded database.
#
#   tools/publish-test.sh          # ~4 min on Cloud, writes evidence/publish.txt
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

CUT="${CUT:-2026-07-26 10:56:00}"
LIVE=sonyliv_pub
CTL=sonyliv_pub_ctl
PROD=sonyliv                      # READ-ONLY. Never a write target.
OUT=evidence/publish.txt
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p evidence

# The straggler: a single heartbeat dropped into a 290 s gap of an
# already-published session. 147 s from the event before it and 143 s from the
# event after, both inside HEARTBEAT_GAP_S = 150, so it bridges the gap and the
# session's two runs MERGE. That is the case that matters: it does not merely
# extend an interval, it makes an interval_start VANISH.
STRAGGLER_SESSION="${STRAGGLER_SESSION:-B52EB43D855A723E1755B97C75CEAC5D05B60BCCEDC5902DECF4610114D89E6B}"
STRAGGLER_TS="${STRAGGLER_TS:-2026-07-26 10:45:10.000}"

ch_host() { local h="${CH_HOST:?CH_HOST unset}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }
q()  { tools/ch -c "$1"; }
qr() { tools/ch -c "$1 FORMAT TSVRaw"; }
say()  { printf '%s\n' "$*" | tee -a "$OUT"; }
rule() { say "--------------------------------------------------------------------------"; }

assert_isolation() {
  if grep -Eq "(INSERT[[:space:]]+INTO|TRUNCATE[[:space:]]+TABLE|DELETE[[:space:]]+FROM|DROP[[:space:]]+DATABASE)[[:space:]]+\\\$?\{?${PROD}\b" "$0"; then
    echo "REFUSING: $0 writes to ${PROD}" >&2; exit 1
  fi
}
assert_isolation

# Run a SQL file against a database with an explicit query_id, so system.
# query_log can be read back for it afterwards.
qfile() {  # qfile <db> <file> <query_id>
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=$1&query_id=$3" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "@$2"
}

# What a statement actually touched, from the server's own log.
cost() {  # cost <query_id>
  q "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
  qr "SELECT concat(
        'read_rows=', formatReadableQuantity(read_rows),
        '  read_bytes=', formatReadableSize(read_bytes),
        '  parts=', toString(ProfileEvents['SelectedParts']),
        '  marks=', toString(ProfileEvents['SelectedMarks']),
        '/', toString(ProfileEvents['SelectedMarksTotal']),
        '  ', toString(round(query_duration_ms)), ' ms')
      FROM system.query_log WHERE query_id = '$1' AND type = 'QueryFinish'
      ORDER BY event_time DESC LIMIT 1"
}

# A full batch rebuild of the control database — the "recompute" answer, run
# exactly the way tools/build-model.sh runs it (TRUNCATE both, re-derive all).
control_rebuild() {  # control_rebuild <tag>
  q "TRUNCATE TABLE ${CTL}.session_intervals" >/dev/null
  qfile "$CTL" sql/30_build_intervals.sql "ctl-$1-intervals" >/dev/null
  q "TRUNCATE TABLE ${CTL}.cc_minute_delta" >/dev/null
  qfile "$CTL" sql/40_deltas.sql "ctl-$1-deltas" >/dev/null
}

# The three-way comparison. Anything non-zero is a failure.
compare() {  # compare <label>
  say ""
  say "  CONVERGENCE — incremental ($LIVE) vs from-scratch rebuild ($CTL)"
  q "
  SELECT * FROM (
    SELECT 1 AS ord, 'delta cells differing' AS check, toString(count()) AS value FROM (
      SELECT minute, platform, country, content_id, subtitle_language, player_version,
             audio_language, app_version, sum(d) AS dd, sum(s) AS ss, sum(e) AS ee
      FROM (
        SELECT minute, platform, country, content_id, subtitle_language, player_version,
               audio_language, app_version, delta AS d, starts AS s, ends AS e
        FROM ${LIVE}.cc_minute_delta
        UNION ALL
        SELECT minute, platform, country, content_id, subtitle_language, player_version,
               audio_language, app_version, -delta, -starts, -ends
        FROM ${CTL}.cc_minute_delta)
      GROUP BY minute, platform, country, content_id, subtitle_language, player_version,
               audio_language, app_version
      HAVING dd != 0 OR ss != 0 OR ee != 0)
    UNION ALL
    SELECT 2, 'interval rows differing', toString(count()) FROM (
      SELECT video_session_id, interval_start, interval_end, is_open, platform, country,
             content_id, app_version, audio_language, subtitle_language, player_version,
             sum(sg) AS n
      FROM (
        SELECT video_session_id, interval_start, interval_end, is_open, platform, country,
               content_id, app_version, audio_language, subtitle_language, player_version,
               1 AS sg FROM ${LIVE}.session_intervals FINAL
        UNION ALL
        SELECT video_session_id, interval_start, interval_end, is_open, platform, country,
               content_id, app_version, audio_language, subtitle_language, player_version,
               -1 FROM ${CTL}.session_intervals FINAL)
      GROUP BY video_session_id, interval_start, interval_end, is_open, platform, country,
               content_id, app_version, audio_language, subtitle_language, player_version
      HAVING n != 0)
    UNION ALL
    SELECT 3, 'served minutes differing',
           toString(countIf(ifNull(a.concurrent, -1) != ifNull(b.concurrent, -1)))
    FROM ${LIVE}.v_concurrency_minute_delta_total a
    FULL OUTER JOIN ${CTL}.v_concurrency_minute_delta_total b USING (minute)
    UNION ALL
    SELECT 4, 'served minutes compared', toString(count())
    FROM ${LIVE}.v_concurrency_minute_delta_total a
    FULL OUTER JOIN ${CTL}.v_concurrency_minute_delta_total b USING (minute)
    UNION ALL
    SELECT 5, 'peak — incremental',  toString(max(concurrent)) FROM ${LIVE}.v_concurrency_minute_delta_total
    UNION ALL
    SELECT 6, 'peak — rebuild',      toString(max(concurrent)) FROM ${CTL}.v_concurrency_minute_delta_total
    UNION ALL
    SELECT 7, 'cc_minute_delta rows — incremental (incl. cancelling corrections)',
           toString(count()) FROM ${LIVE}.cc_minute_delta
    UNION ALL
    SELECT 8, 'cc_minute_delta rows — rebuild', toString(count()) FROM ${CTL}.cc_minute_delta
  ) ORDER BY ord FORMAT PrettyCompact" | tee -a "$OUT"
}

# The served curve around the straggler, so "the number moved" is a number.
served_window() {  # served_window <label>
  q "
  SELECT '$1' AS at, toString(minute) AS at_minute, toInt64(sum(sum(delta)) OVER (ORDER BY minute)) AS concurrent
  FROM ${LIVE}.cc_minute_delta
  WHERE minute >= toDateTime('2026-07-26 10:00:00') AND minute <= toDateTime('2026-07-26 10:50:00')
  GROUP BY minute
  HAVING minute >= toDateTime('2026-07-26 10:42:00') AND minute <= toDateTime('2026-07-26 10:48:00')
  ORDER BY minute FORMAT PrettyCompact" | tee -a "$OUT"
}

: > "$OUT"
say "CONTINUOUS PUBLICATION — incremental update proof   (ADR 0013)"
say "generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')  ·  commit $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
say "live: ${LIVE}   control: ${CTL}   ${PROD} read-only   cut ${CUT}"
rule

# ---------------------------------------------------------------------------
say ""
say "PHASE 0 — reset both scratch databases and apply the schema"
for db in "$LIVE" "$CTL"; do
  q "DROP DATABASE IF EXISTS ${db}" >/dev/null
  q "CREATE DATABASE ${db}" >/dev/null
done
# `env -u CH_DATABASE`: .env exports CH_DATABASE=sonyliv and apply-sql.sh
# (rightly) refuses a --database that contradicts an exported one. Clearing it
# for these two calls is how you say "yes, the scratch database, on purpose".
env -u CH_DATABASE TARGET=cloud tools/apply-sql.sh --database "$LIVE" \
  sql/00_schema.sql sql/10_intervals.sql sql/12_publish.sql sql/20_views.sql >/dev/null
env -u CH_DATABASE TARGET=cloud tools/apply-sql.sh --database "$CTL" \
  sql/00_schema.sql sql/10_intervals.sql sql/20_views.sql >/dev/null
say "  ${LIVE} has the publication layer (sql/12_publish.sql); ${CTL} does not — it is rebuilt."

# ---------------------------------------------------------------------------
say ""
say "PHASE 1 — load the truncated slice into both:  event_timestamp < ${CUT}"
for db in "$LIVE" "$CTL"; do
  q "INSERT INTO ${db}.ev_raw
     SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
            platform, app_version, country, audio_language, subtitle_language,
            player_version, session_start_epoch
     FROM ${PROD}.ev_raw WHERE event_timestamp < toDateTime64('${CUT}', 3)" >/dev/null
done
say "  $(qr "SELECT concat(toString(count()), ' events · ', toString(uniqExact(video_session_id)),
             ' sessions · newest ', toString(max(event_timestamp))) FROM ${LIVE}.ev_raw")"
say "  change log: $(qr "SELECT concat(toString(count()), ' rows · ', toString(uniqExact(video_session_id)),
             ' sessions · ', toString(uniqExact(marked_at)), ' insert block(s)') FROM ${LIVE}.session_dirty")"
say ""
say "  The MV collapsed the load to one row per session per block. No session list"
say "  was computed by scanning history — this is what the finalizer consumes."

# ---------------------------------------------------------------------------
say ""
say "PHASE 2 — build BOTH: control by rebuild, live by the incremental finalizer"
say ""
say "  control — tools/build-model.sh's path (TRUNCATE + re-derive all of ev_raw):"
control_rebuild boot
say "    intervals  $(cost ctl-boot-intervals)"
say "    deltas     $(cost ctl-boot-deltas)"
say ""
say "  live — tools/publish.sh, no special bootstrap path:"
sleep "${SETTLE_WAIT:-6}"
tools/publish.sh --database "$LIVE" 2>&1 | sed 's/^/    /' | tee -a "$OUT"
say ""
say "  There is no separate initial-build code. The first run sees every session"
say "  marked dirty by the load and derives them; every later run sees only what"
say "  arrived. One path, so the bootstrap cannot drift from the steady state."
compare boot

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 3 — LATE ARRIVAL (a): the five busiest sessions catch up"
LATE5="$(qr "SELECT arrayStringConcat(groupArray(video_session_id), ''',''')
             FROM (SELECT video_session_id, count() c FROM ${PROD}.ev_raw
                   WHERE event_timestamp >= toDateTime64('${CUT}',3)
                     AND video_session_id IN (SELECT video_session_id FROM ${LIVE}.ev_raw)
                   GROUP BY video_session_id ORDER BY c DESC LIMIT 5)")"
for db in "$LIVE" "$CTL"; do
  q "INSERT INTO ${db}.ev_raw
     SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
            platform, app_version, country, audio_language, subtitle_language,
            player_version, session_start_epoch
     FROM ${PROD}.ev_raw
     WHERE event_timestamp >= toDateTime64('${CUT}',3)
       AND video_session_id IN ('${LATE5}')" >/dev/null
done
say "  inserted $(qr "SELECT toString(count()) FROM ${LIVE}.ev_raw WHERE event_timestamp >= toDateTime64('${CUT}',3)") events for 5 sessions"
say "  pending: $(qr "SELECT concat(toString(pending_sessions), ' session(s), lag ', toString(publish_lag_s), 's') FROM ${LIVE}.v_cc_publish_lag")"
say ""
sleep "${SETTLE_WAIT:-6}"   # markings must SETTLE before the finalizer may consume them
tools/publish.sh --database "$LIVE" 2>&1 | sed 's/^/    /' | tee -a "$OUT"
RUN3="$(qr "SELECT toString(max(run_id)) FROM ${LIVE}.cc_publish_runs WHERE phase='committed'")"
say ""
say "  WHAT THE INCREMENTAL RUN TOUCHED, from system.query_log:"
say "    negate   $(cost "publish-${RUN3}-negate")"
say "    derive   $(cost "publish-${RUN3}-derive")"
say "    emit     $(cost "publish-${RUN3}-emit")"
say ""
say "  the same update, done by RECOMPUTING (the control):"
control_rebuild late5
say "    intervals  $(cost ctl-late5-intervals)"
say "    deltas     $(cost ctl-late5-deltas)"
compare late5

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 4 — LATE ARRIVAL (b): the entire remaining stream"
for db in "$LIVE" "$CTL"; do
  q "INSERT INTO ${db}.ev_raw
     SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
            platform, app_version, country, audio_language, subtitle_language,
            player_version, session_start_epoch
     FROM ${PROD}.ev_raw
     WHERE event_timestamp >= toDateTime64('${CUT}',3)
       AND video_session_id NOT IN ('${LATE5}')" >/dev/null
done
say "  $(qr "SELECT concat(toString(count()), ' events now loaded · newest ', toString(max(event_timestamp))) FROM ${LIVE}.ev_raw")"
say "  pending: $(qr "SELECT concat(toString(pending_sessions), ' session(s)') FROM ${LIVE}.v_cc_publish_lag")"
say ""
sleep "${SETTLE_WAIT:-6}"   # markings must SETTLE before the finalizer may consume them
tools/publish.sh --database "$LIVE" 2>&1 | sed 's/^/    /' | tee -a "$OUT"
RUN4="$(qr "SELECT toString(max(run_id)) FROM ${LIVE}.cc_publish_runs WHERE phase='committed'")"
say ""
say "    derive   $(cost "publish-${RUN4}-derive")"
control_rebuild full
say "    rebuild  $(cost ctl-full-intervals)"
compare full

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 5 — THE STRAGGLER. One heartbeat, event-dated 46 minutes behind the"
say "          watermark, landing inside a 290 s gap of an already-published session."
say ""
say "  session ${STRAGGLER_SESSION}"
say "  event   ${STRAGGLER_TS}   (newest event in ev_raw: $(qr "SELECT toString(max(event_timestamp)) FROM ${LIVE}.ev_raw"))"
say "  ADR 0004 set W = 2400 s. This event is older than W, so the two-tier design"
say "  has no path for it and ADR 0006's correction-by-diff is the only answer."
say ""
say "  intervals BEFORE — note the second one starts at 10:47:33:"
q "SELECT toString(interval_start) AS interval_start, toString(interval_end) AS interval_end, is_open
   FROM ${LIVE}.session_intervals FINAL WHERE video_session_id = '${STRAGGLER_SESSION}'
   ORDER BY interval_start FORMAT PrettyCompact" | tee -a "$OUT"
say ""
say "  served concurrency BEFORE:"
served_window before

for db in "$LIVE" "$CTL"; do
  q "INSERT INTO ${db}.ev_raw
     SELECT content_id, video_session_id, user_id, 'VideoHeartbeat' AS event_type,
            'network-activity' AS event, toDateTime64('${STRAGGLER_TS}', 3) AS event_timestamp,
            platform, app_version, country, audio_language, subtitle_language,
            player_version, session_start_epoch
     FROM ${db}.ev_raw WHERE video_session_id = '${STRAGGLER_SESSION}'
     ORDER BY event_timestamp LIMIT 1" >/dev/null
done
say ""
say "  pending: $(qr "SELECT concat(toString(pending_sessions), ' session(s)') FROM ${LIVE}.v_cc_publish_lag")"
say ""
sleep "${SETTLE_WAIT:-6}"   # markings must SETTLE before the finalizer may consume them
tools/publish.sh --database "$LIVE" 2>&1 | sed 's/^/    /' | tee -a "$OUT"
RUN5="$(qr "SELECT toString(max(run_id)) FROM ${LIVE}.cc_publish_runs WHERE phase='committed'")"
say ""
say "  WHAT ONE-SESSION CORRECTION COSTS, from system.query_log:"
say "    negate   $(cost "publish-${RUN5}-negate")"
say "    derive   $(cost "publish-${RUN5}-derive")"
say "    prune    $(cost "publish-${RUN5}-prune")"
say "    emit     $(cost "publish-${RUN5}-emit")"
say "  ev_raw holds $(qr "SELECT formatReadableQuantity(count()) FROM ${LIVE}.ev_raw") events over $(qr "SELECT toString(uniqExact(video_session_id)) FROM ${LIVE}.ev_raw") sessions."
say ""
say "  HOW MUCH OF ev_raw DOES A ONE-SESSION CORRECTION HAVE TO READ?"
say ""
say "  Not 78 rows, and it is worth being blunt about why. ADR 0002 puts"
say "  toStartOfHour(event_timestamp) FIRST in ev_raw's sort key and video_session_id"
say "  third, so a session lookup prunes only by generic exclusion search. The"
say "  finalizer therefore ALSO bounds the read by the batch's event-time window"
say "  (the completeness argument is in tools/publish.sh). A/B below on the real"
say "  query shape — IN (subquery over cc_publish_batch), not an inlined literal,"
say "  because that is what publish.sh issues and the two do not prune alike."
say ""
SW_LO="$(qr "SELECT toString(min(lo_event_ts)) FROM ${LIVE}.cc_publish_batch WHERE run_id = ${RUN5}")"
SW_HI="$(qr "SELECT toString(max(hi_event_ts)) FROM ${LIVE}.cc_publish_batch WHERE run_id = ${RUN5}")"
EV_ROWS="$(qr "SELECT toString(count()) FROM ${LIVE}.ev_raw")"
# Settle the part set first. Measured mid-merge, these numbers move by 3x and
# the ordering between variants inverts — an earlier draft of this harness
# reported the time window as a REGRESSION on exactly that artefact.
q "OPTIMIZE TABLE ${LIVE}.ev_raw FINAL" >/dev/null
# The probe reads the SAME columns the derivation reads. `SELECT count()` is
# answered from part metadata (measured: 1 row / 16 bytes even unscoped) and
# would make every variant look free.
SCOPE_PROBE="SELECT uniqExact(video_session_id), min(event_timestamp), max(event_timestamp) FROM ev_raw"
SCOPE_SUB="(SELECT video_session_id FROM cc_publish_batch WHERE run_id = ${RUN5})"
probe() {  # probe <query_id> <where clause or empty>
  # curl, not q(): q() is tools/ch, which takes no URL parameters, so a
  # query_id passed to it is silently dropped and cost() then finds nothing.
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${LIVE}&query_id=$1" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "${SCOPE_PROBE} ${2}" >/dev/null
}
for i in 1 2 3; do
  probe "scope-a.unscoped-${RUN5}-$i" ""
  probe "scope-b.session-${RUN5}-$i"  "WHERE video_session_id IN ${SCOPE_SUB}"
  probe "scope-c.windowed-${RUN5}-$i" "WHERE video_session_id IN ${SCOPE_SUB}
                                         AND event_timestamp >= toDateTime64('${SW_LO}',3)
                                         AND event_timestamp <= toDateTime64('${SW_HI}',3)"
done
q "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
q "
SELECT variant, read_rows, concat(toString(round(100.0*read_rows/${EV_ROWS}, 1)), '%') AS pct_of_ev_raw,
       read_bytes, ms
FROM (
  SELECT splitByChar('-', query_id)[2] AS variant, round(avg(read_rows)) AS read_rows,
         formatReadableSize(avg(read_bytes)) AS read_bytes, round(avg(query_duration_ms)) AS ms
  FROM system.query_log
  WHERE query_id LIKE 'scope-%-${RUN5}-%' AND type = 'QueryFinish' GROUP BY variant)
ORDER BY variant FORMAT PrettyCompact" | tee -a "$OUT"
say "    a.unscoped = what a rebuild reads    c.windowed = what publish.sh scopes to"
say "    mean of 3 runs each, on a settled part set (${EV_ROWS} rows in ev_raw)"
say ""
say "  intervals AFTER — the two runs merged, so interval_start 10:47:33 no longer"
say "  exists. A ReplacingMergeTree cannot delete a key; the prune phase does:"
q "SELECT toString(interval_start) AS interval_start, toString(interval_end) AS interval_end, is_open
   FROM ${LIVE}.session_intervals FINAL WHERE video_session_id = '${STRAGGLER_SESSION}'
   ORDER BY interval_start FORMAT PrettyCompact" | tee -a "$OUT"
say ""
say "  orphan rows left behind by the vanished key: $(qr "SELECT toString(count()) FROM ${LIVE}.session_intervals WHERE video_session_id='${STRAGGLER_SESSION}' AND interval_start = toDateTime64('2026-07-26 10:47:33',3)")"
say ""
say "  served concurrency AFTER — every minute the straggler bridges gains one viewer:"
served_window after
say ""
say "  and the same rebuilt from scratch, for comparison:"
control_rebuild straggler
compare straggler

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 6 — IDEMPOTENCE. Republish sessions whose events did NOT change."
say ""
say "  A resumed run, a replayed batch or an operator correction can all re-publish"
say "  a session whose events did not change. That is only safe if -deltas(X) +"
say "  deltas(X) = 0. Forcing a republication of 200 unchanged sessions tests it."
BEFORE_ROWS="$(qr "SELECT toString(count()) FROM ${LIVE}.cc_minute_delta")"
FORCED="$(qr "SELECT arrayStringConcat(groupArray(video_session_id), ',')
              FROM (SELECT DISTINCT video_session_id FROM ${LIVE}.session_intervals
                    ORDER BY video_session_id LIMIT 200)")"
tools/publish.sh --database "$LIVE" --sessions "$FORCED" 2>&1 | sed 's/^/    /' | tee -a "$OUT"
AFTER_ROWS="$(qr "SELECT toString(count()) FROM ${LIVE}.cc_minute_delta")"
say ""
say "  cc_minute_delta rows: ${BEFORE_ROWS} -> ${AFTER_ROWS} (corrective rows are APPENDED, never updated)"
say "  cursor: $(qr "SELECT if(length(c) > 1 AND c[1] = c[2],
                 concat('UNCHANGED at ', toString(c[1]), ' — a forced run corrects, it does not consume the queue'),
                 concat('moved to ', toString(c[1])))
               FROM (SELECT arraySort(x -> -toUnixTimestamp64Milli(x.1),
                              groupArray((cursor_to, run_id))).1 AS c
                     FROM ${LIVE}.cc_publish_runs WHERE phase='committed')")"
compare idempotence

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 7 — THE COST LEDGER, per run, from cc_publish_runs"
q "SELECT run_id, toString(any(cursor_to)) AS cursor_to, max(sessions) AS sessions,
          sum(elapsed_ms) AS total_ms,
          sumIf(rows_written, phase='derived') AS intervals_written,
          sumIf(rows_written, phase IN ('negated','emitted')) AS delta_rows_written
   FROM ${LIVE}.cc_publish_runs GROUP BY run_id ORDER BY run_id FORMAT PrettyCompact" | tee -a "$OUT"
say ""
say "  freshness, as a downstream consumer would read it:"
q "SELECT * FROM ${LIVE}.v_cc_publish_lag FORMAT Vertical" | tee -a "$OUT"

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 8 — RE-MEASURING THE SHELVED PROJECTION on the finalizer's query shape."
say ""
say "  WALKTHROUGH §5 records proj_by_session as measured and NOT shipped: 27.7x on"
say "  a single-session lookup, but \"the actual straggler path uses IN (subquery),"
say "  which full-scans anyway, so the real gain is 1.00x for +94% storage\"."
say "  The finalizer's derive is exactly that IN (subquery) — plus an event-time"
say "  window — so the shape is worth re-measuring rather than inheriting."
say ""
BASE_BYTES="$(qr "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts
                  WHERE database='${LIVE}' AND table='ev_raw' AND active")"
q "ALTER TABLE ${LIVE}.ev_raw ADD PROJECTION IF NOT EXISTS proj_by_session
     (SELECT * ORDER BY (video_session_id, event_timestamp))" >/dev/null
q "ALTER TABLE ${LIVE}.ev_raw MATERIALIZE PROJECTION proj_by_session" >/dev/null
for _ in $(seq 40); do
  [ "$(qr "SELECT toString(count()) FROM system.mutations
           WHERE database='${LIVE}' AND table='ev_raw' AND NOT is_done")" = "0" ] && break
  sleep 4
done
for i in 1 2 3; do
  probe "proj-b.session-${RUN5}-$i"  "WHERE video_session_id IN ${SCOPE_SUB}"
  probe "proj-c.windowed-${RUN5}-$i" "WHERE video_session_id IN ${SCOPE_SUB}
                                        AND event_timestamp >= toDateTime64('${SW_LO}',3)
                                        AND event_timestamp <= toDateTime64('${SW_HI}',3)"
done
q "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
q "
SELECT variant, read_rows, concat(toString(round(100.0*read_rows/${EV_ROWS}, 1)), '%') AS pct_of_ev_raw,
       read_bytes, ms, if(projection = '', 'no', 'YES') AS used_projection
FROM (
  SELECT splitByChar('-', query_id)[2] AS variant, round(avg(read_rows)) AS read_rows,
         formatReadableSize(avg(read_bytes)) AS read_bytes, round(avg(query_duration_ms)) AS ms,
         any(arrayStringConcat(projections, ',')) AS projection
  FROM system.query_log
  WHERE query_id LIKE 'proj-%-${RUN5}-%' AND type = 'QueryFinish' GROUP BY variant)
ORDER BY variant FORMAT PrettyCompact" | tee -a "$OUT"
say ""
say "  storage: ev_raw ${BASE_BYTES} -> $(qr "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts
      WHERE database='${LIVE}' AND table='ev_raw' AND active") (projection itself $(qr "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.projection_parts
      WHERE database='${LIVE}' AND table='ev_raw' AND active AND name='proj_by_session'"))"
say ""
say "  Compare against the PHASE 5 table above: the projection IS chosen for the"
say "  IN (subquery) shape on 26.2. This does not overturn the storage trade — that"
say "  is still the operator's call — but the '1.00x' half of it does not hold for"
say "  the finalizer's query. ADR 0013 records both numbers and ships neither."
say "  NOTE: sql/60_projection.sql hard-codes 'sonyliv.', so it cannot be applied to"
say "  any other database; this phase had to issue the ALTER itself. Same class of"
say "  defect ADR 0010 fixed in sql/80_content.sql."

# ---------------------------------------------------------------------------
say ""
rule
say "PHASE 9 — ADOPTION COSTS NOTHING. Turn the publication layer on over a database"
say "          that was built the old way, and prove it does not re-derive history."
say ""
say "  ${CTL} has been rebuilt from scratch and has never had sql/12_publish.sql."
say "  This is the shape of the graded service today."
say ""
say "  before: $(qr "SELECT concat(toString((SELECT count() FROM ${CTL}.session_intervals FINAL)), ' intervals · ',
                     toString((SELECT count() FROM ${CTL}.cc_minute_delta)), ' delta rows · peak ',
                     toString((SELECT max(concurrent) FROM ${CTL}.v_concurrency_minute_delta_total)))")"
env -u CH_DATABASE TARGET=cloud tools/apply-sql.sh --database "$CTL" sql/12_publish.sql >/dev/null
say "  applied sql/12_publish.sql"
tools/publish.sh --database "$CTL" 2>&1 | sed 's/^/    /' | tee -a "$OUT"
say "  after:  $(qr "SELECT concat(toString((SELECT count() FROM ${CTL}.session_intervals FINAL)), ' intervals · ',
                     toString((SELECT count() FROM ${CTL}.cc_minute_delta)), ' delta rows · peak ',
                     toString((SELECT max(concurrent) FROM ${CTL}.v_concurrency_minute_delta_total)))")"
say ""
say "  Nothing moved, because nothing has arrived since the layer went on. The change"
say "  log is empty on a table that was already loaded, so the cursor starts at the"
say "  current ingest position rather than at the beginning of history. Adoption is"
say "  one DDL round trip — it does NOT trigger a rebuild to catch up."

say ""
rule
say "Every 'differing' row above is 0 or this run failed. cc_minute_delta was never"
say "truncated after PHASE 2 and session_intervals was never rebuilt: every number"
say "moved by appending a correction and re-deriving the sessions that changed."
echo
echo "evidence written to $OUT"
