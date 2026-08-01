#!/usr/bin/env bash
# ============================================================================
# evidence/publish-visibility/20-dip-realistic.sh — EXPERIMENT 2: the realistic
# reproduction. Land the whole remaining stream (everything >= CUT, ~7,7xx
# sessions) as a late arrival and poll two probe regions across all three
# tiers while the publisher absorbs it.
#
#   probe A (10:54) — inside already-published coverage: expect the NEGATE dip.
#   probe B (11:30) — inside the incoming data: expect minute tier to jump at
#                     emit while hour/user tiers stay stale until their phases.
#
# Writes: sonyliv_q29vis only.
# Output: 20-dip-realistic.txt (log) and 20-poll-realistic.tsv (samples).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && . ./.env && set +a

DB=sonyliv_q29vis
PROD=sonyliv                          # READ-ONLY
CUT="${CUT:-2026-07-26 10:56:00}"
DIR=evidence/publish-visibility
OUT="$DIR/20-dip-realistic.txt"
POLL="$DIR/20-poll-realistic.tsv"

ch_host() { local h="${CH_HOST:?}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }
q() {
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${DB}" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"
}
qd() {  # default database (for the cross-db INSERT ... SELECT)
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"
}
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

if grep -Eq "(INSERT[[:space:]]+INTO|TRUNCATE|DELETE[[:space:]]+FROM|DROP[[:space:]]+DATABASE)[[:space:]]+\\\$?\{?${PROD}\b" "$0"; then
  echo "REFUSING: $0 writes to ${PROD}" >&2; exit 1
fi

: > "$OUT"
say "Q29 EXPERIMENT 2 — realistic late-arrival batch (rest of stream >= ${CUT})"
say "db ${DB} · $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

POLL_SQL="SELECT
  toString(now64(3)) || '\t' ||
  toString(toInt64(ifNull((SELECT sum(delta) FROM cc_minute_delta
    WHERE minute >= toDateTime('2026-07-26 10:00:00') AND minute <= toDateTime('2026-07-26 10:54:00')), 0))) || '\t' ||
  toString(toInt64(ifNull((SELECT max(peak) FROM v_concurrency_hour_total
    WHERE hour = toDateTime('2026-07-26 10:00:00')), 0))) || '\t' ||
  toString(toInt64(ifNull((SELECT max(concurrent_users) FROM v_user_concurrency_minute_total
    WHERE minute = toDateTime('2026-07-26 10:54:00')), 0))) || '\t' ||
  toString(toInt64(ifNull((SELECT sum(delta) FROM cc_minute_delta
    WHERE minute >= toDateTime('2026-07-26 11:00:00') AND minute <= toDateTime('2026-07-26 11:30:00')), 0))) || '\t' ||
  toString(toInt64(ifNull((SELECT max(peak) FROM v_concurrency_hour_total
    WHERE hour = toDateTime('2026-07-26 11:00:00')), 0))) || '\t' ||
  toString(toInt64(ifNull((SELECT max(concurrent_users) FROM v_user_concurrency_minute_total
    WHERE minute = toDateTime('2026-07-26 11:30:00')), 0)))
FORMAT TSVRaw"

printf 'server_ts\tmA_minute\tmA_hourpeak\tmA_users\tmB_minute\tmB_hourpeak\tmB_users\n' > "$POLL"

say "baseline (3 reads):  [probe A: 10:54 minute/hour-peak/users | probe B: 11:30 same]"
for i in 1 2 3; do q "$POLL_SQL" | tee -a "$OUT"; done

say ""
say "landing the remaining stream…"
qd "INSERT INTO ${DB}.ev_raw
    SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
           platform, app_version, country, audio_language, subtitle_language,
           player_version, session_start_epoch
    FROM ${PROD}.ev_raw WHERE event_timestamp >= toDateTime64('${CUT}', 3)" >/dev/null
say "loaded: $(q "SELECT concat(toString(count()), ' events · ', toString(uniqExact(video_session_id)), ' sessions') FROM ev_raw FORMAT TSVRaw") (cumulative)"

say "settling $(( ${PUBLISH_SETTLE_S:-5} + 1 ))s…"
sleep "$(( ${PUBLISH_SETTLE_S:-5} + 1 ))"

poller() { while :; do q "$POLL_SQL" >> "$POLL" 2>/dev/null || true; done; }
poller & PPOLL=$!
trap 'kill $PPOLL 2>/dev/null || true' EXIT

say ""
say "publishing…"
tools/publish.sh --database "$DB" 2>&1 | sed 's/^/  /' | tee -a "$OUT"

sleep 2
kill "$PPOLL" 2>/dev/null || true; wait "$PPOLL" 2>/dev/null || true
trap - EXIT

say ""
say "post-run (3 reads):"
for i in 1 2 3; do q "$POLL_SQL" | tee -a "$OUT"; done

say ""
say "poller samples: $(( $(wc -l < "$POLL") - 1 ))  ->  ${POLL}"
say ""
say "phase timings from system.query_log (server-side truth):"
q "SYSTEM FLUSH LOGS" >/dev/null 2>&1 || true
q "SELECT
     splitByChar('-', query_id)[3] AS phase,
     min(event_time_microseconds) AS started,
     max(event_time_microseconds + toIntervalMillisecond(query_duration_ms)) AS finished,
     max(query_duration_ms) AS dur_ms
   FROM system.query_log
   WHERE query_id LIKE concat('publish-', toString((SELECT max(run_id) FROM cc_publish_runs)), '-%')
     AND type = 'QueryFinish'
   GROUP BY phase ORDER BY started FORMAT PrettyCompact" | tee -a "$OUT"
