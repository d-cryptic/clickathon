#!/usr/bin/env bash
# ============================================================================
# evidence/publish-visibility/30-oneblock-fix.sh — EXPERIMENT 3: prototype of
# the Codex §8.3 minimum fix, WITHOUT touching tools/publish.sh.
#
# Same forced republication as experiment 1 (300 unchanged sessions covering
# the probe minute), but the phase order is changed so nothing corrective
# touches cc_minute_delta until the very end:
#
#   1. stage-negate : -deltas(intervals_old)  -> q29_stage   (NOT the serving table)
#   2. derive       : new intervals @ BV      -> session_intervals   (unchanged)
#   3. prune        : superseded intervals deleted                   (unchanged)
#   4. stage-emit   : +deltas(intervals_new)  -> q29_stage   (NOT the serving table)
#   5. swap         : INSERT INTO cc_minute_delta SELECT * FROM q29_stage
#                     — the ONLY write the serving table sees, one statement.
#
# The same poller from experiment 1 races it. If the dip is a phase-visibility
# artifact, it must vanish here; system.part_log for the swap shows how many
# parts the single insert produced and in which partitions (the honest bound on
# "atomic").
#
# Writes: sonyliv_q29vis only.
# Output: 30-oneblock-fix.txt and 30-poll-oneblock.tsv.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && . ./.env && set +a

DB=sonyliv_q29vis
N_SESSIONS="${N_SESSIONS:-300}"
PROBE="2026-07-26 10:54:00"
HOUR="2026-07-26 10:00:00"
DIR=evidence/publish-visibility
OUT="$DIR/30-oneblock-fix.txt"
POLL="$DIR/30-poll-oneblock.tsv"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ch_host() { local h="${CH_HOST:?}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }
q() {
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${DB}${2:-}" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"
}
qf() {
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${DB}&query_id=$2" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "@$1"
}
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

template_or_die() {
  local src="$1" dst="$2" marker="$3"; shift 3
  sed "$@" "$src" > "$dst"
  grep -q "$marker" "$dst" || { echo "template of $src did not apply: $marker absent" >&2; exit 1; }
}

: > "$OUT"
RUN="q29fix$(date +%s)"
say "Q29 EXPERIMENT 3 — one-block correction (staged diff, single serving insert)"
say "probe minute ${PROBE} · db ${DB} · run ${RUN} · $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

LIST="$(q "SELECT arrayStringConcat(groupArray(video_session_id), ',') FROM (
             SELECT DISTINCT video_session_id FROM session_intervals FINAL
             WHERE interval_start < toDateTime('${PROBE}') + INTERVAL 60 SECOND
               AND interval_end   >= toDateTime('${PROBE}')
             ORDER BY video_session_id LIMIT ${N_SESSIONS}) FORMAT TSVRaw")"
IN_LIST="'$(printf '%s' "$LIST" | sed "s/,/','/g")'"
SCOPE="video_session_id IN (${IN_LIST})"
say "claimed ${N_SESSIONS} sessions covering the probe minute (same shape as experiment 1)"

LO="$(q "SELECT toString(min(interval_start)) FROM session_intervals FINAL WHERE $SCOPE FORMAT TSVRaw")"
HI="$(q "SELECT toString(max(interval_end))   FROM session_intervals FINAL WHERE $SCOPE FORMAT TSVRaw")"
BV="$(q "SELECT toString(greatest(toUInt64(toUnixTimestamp(now())),
                                  toUInt64(ifNull(max(build_version), 0)) + 1))
         FROM session_intervals FORMAT TSVRaw")"
say "window ${LO} .. ${HI} · build_version ${BV}"

# Staging table: same shape as cc_minute_delta, plain types, throwaway.
q "DROP TABLE IF EXISTS q29_stage" >/dev/null
q "CREATE TABLE q29_stage (
     minute DateTime, platform String, country String, content_id Int64,
     subtitle_language String, player_version String, audio_language String,
     app_version String, delta Int64, starts Int64, ends Int64)
   ENGINE = MergeTree ORDER BY minute" >/dev/null

# stage-negate: the negate template, redirected into staging.
template_or_die sql/40_deltas.sql "$TMP/stage_neg.sql" 'PUBLISH_NEGATE' \
  -e "s|^INSERT INTO cc_minute_delta\$|INSERT INTO q29_stage /*PUBLISH_STAGE*/|" \
  -e "s|^    FROM session_intervals FINAL\$|    FROM session_intervals FINAL WHERE $SCOPE /*PUBLISH_SCOPE*/|" \
  -e "s|^    sum(d)  AS delta,\$|    -sum(d)  AS delta, /*PUBLISH_NEGATE*/|" \
  -e "s|^    sum(op) AS starts,\$|    -sum(op) AS starts,|" \
  -e "s|^    sum(cl) AS ends\$|    -sum(cl) AS ends|"
grep -q 'PUBLISH_STAGE' "$TMP/stage_neg.sql" || { echo "stage redirect lost" >&2; exit 1; }

# derive: identical to publish.sh's phase.
template_or_die sql/30_build_intervals.sql "$TMP/derive.sql" 'PUBLISH_SCOPE' \
  -e "s|^        FROM ev_raw\$|        FROM ev_raw WHERE $SCOPE AND event_timestamp >= toDateTime64('$LO',3) AND event_timestamp <= toDateTime64('$HI',3) /*PUBLISH_SCOPE*/|" \
  -e "s|^        toUInt64(toUnixTimestamp(now())) AS build_version,\$|        toUInt64($BV) AS build_version, /*PUBLISH_BV*/|"

# stage-emit: the emit template, redirected into staging.
template_or_die sql/40_deltas.sql "$TMP/stage_pos.sql" 'PUBLISH_SCOPE' \
  -e "s|^INSERT INTO cc_minute_delta\$|INSERT INTO q29_stage /*PUBLISH_STAGE*/|" \
  -e "s|^    FROM session_intervals FINAL\$|    FROM session_intervals FINAL WHERE $SCOPE /*PUBLISH_SCOPE*/|"
grep -q 'PUBLISH_STAGE' "$TMP/stage_pos.sql" || { echo "stage redirect lost" >&2; exit 1; }

POLL_SQL="SELECT
  toString(now64(3)) || '\t' ||
  toString((SELECT toInt64(sum(delta)) FROM cc_minute_delta
            WHERE minute >= toDateTime('${HOUR}') AND minute <= toDateTime('${PROBE}'))) || '\t' ||
  toString((SELECT toInt64(max(peak)) FROM v_concurrency_hour_total
            WHERE hour = toDateTime('${HOUR}'))) || '\t' ||
  toString((SELECT toInt64(ifNull(max(concurrent_users), 0)) FROM v_user_concurrency_minute_total
            WHERE minute = toDateTime('${PROBE}')))
FORMAT TSVRaw"

printf 'server_ts\tminute_cc\thour_peak\tuser_cc\n' > "$POLL"
poller() { while :; do q "$POLL_SQL" >> "$POLL" 2>/dev/null || true; done; }

say "baseline (3 reads):"
for i in 1 2 3; do q "$POLL_SQL" | tee -a "$OUT"; done

poller & PPOLL=$!
trap 'kill $PPOLL 2>/dev/null || true; rm -rf "$TMP"' EXIT

t0=$(python3 -c 'import time; print(int(time.time()*1000))')
qf "$TMP/stage_neg.sql" "${RUN}-stageneg"  >/dev/null
qf "$TMP/derive.sql"    "${RUN}-derive"    >/dev/null
q "DELETE FROM session_intervals WHERE $SCOPE AND build_version < $BV" "&query_id=${RUN}-prune" >/dev/null
qf "$TMP/stage_pos.sql" "${RUN}-stagepos"  >/dev/null
# THE swap: the one write the serving table sees.
q "INSERT INTO cc_minute_delta
   SELECT minute, platform, country, content_id, subtitle_language, player_version,
          audio_language, app_version, delta, starts, ends
   FROM q29_stage" "&query_id=${RUN}-swap" >/dev/null
t1=$(python3 -c 'import time; print(int(time.time()*1000))')
say ""
say "run complete: $((t1-t0)) ms wall for stage-neg + derive + prune + stage-emit + swap"

sleep 2
kill "$PPOLL" 2>/dev/null || true; wait "$PPOLL" 2>/dev/null || true
trap 'rm -rf "$TMP"' EXIT

say ""
say "post-run (3 reads):"
for i in 1 2 3; do q "$POLL_SQL" | tee -a "$OUT"; done

say ""
DIPPED="$(awk -F'\t' 'NR>1 && $2 != 2825 {n++} END {print n+0}' "$POLL")"
say "poller samples: $(( $(wc -l < "$POLL") - 1 ))  ·  samples deviating from 2825: ${DIPPED}"

say ""
say "phase timings (system.query_log):"
q "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
q "SELECT query_id, event_time_microseconds AS started,
          event_time_microseconds + toIntervalMillisecond(query_duration_ms) AS finished,
          query_duration_ms AS dur_ms, written_rows
   FROM system.query_log
   WHERE query_id LIKE '${RUN}-%' AND type = 'QueryFinish'
   ORDER BY started FORMAT PrettyCompact" | tee -a "$OUT"

say ""
say "parts the swap insert created (system.part_log — the honest atomicity bound):"
q "SELECT partition_id, part_name, rows
   FROM system.part_log
   WHERE query_id = '${RUN}-swap' AND event_type = 'NewPart'
   ORDER BY partition_id FORMAT PrettyCompact" | tee -a "$OUT"

say ""
say "convergence check — the staged path must land on the same serving numbers:"
q "SELECT toString(minute) AS minute, toInt64(sum(sum(delta)) OVER (ORDER BY minute)) AS concurrent
   FROM cc_minute_delta
   WHERE minute >= toDateTime('${HOUR}') AND minute <= toDateTime('${PROBE}')
   GROUP BY minute ORDER BY minute DESC LIMIT 3 FORMAT PrettyCompact" | tee -a "$OUT"

q "DROP TABLE IF EXISTS q29_stage" >/dev/null
