#!/usr/bin/env bash
# ============================================================================
# evidence/publish-visibility/10-dip-forced.sh — EXPERIMENT 1: the deterministic
# reproduction. Force-republish N unchanged sessions that cover the probe
# minute while a reader polls all three tiers at that minute.
#
# Forced republication of UNCHANGED sessions appends -deltas(X) then +deltas(X):
# the true answer never moves, so any deviation a reader observes is pure
# publish-visibility artifact. Between the negate and emit phases the minute
# curve should DROP by exactly the forced sessions' contribution; the hour and
# user tiers should lag further (they are re-derived in later phases).
#
# Writes: sonyliv_q29vis only.
# Output: 10-dip-forced.txt (log) and 10-poll-forced.tsv (poller samples).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && . ./.env && set +a

DB=sonyliv_q29vis
N_SESSIONS="${N_SESSIONS:-300}"
PROBE="2026-07-26 10:54:00"
HOUR="2026-07-26 10:00:00"
DIR=evidence/publish-visibility
OUT="$DIR/10-dip-forced.txt"
POLL="$DIR/10-poll-forced.tsv"

ch_host() { local h="${CH_HOST:?}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }
q() {
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/?database=${DB}" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"
}
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "Q29 EXPERIMENT 1 — forced republication of ${N_SESSIONS} unchanged sessions"
say "probe minute ${PROBE} · db ${DB} · $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Sessions whose published coverage includes the probe minute — the ones whose
# negation the probe read will feel.
LIST="$(q "SELECT arrayStringConcat(groupArray(video_session_id), ',') FROM (
             SELECT DISTINCT video_session_id FROM session_intervals FINAL
             WHERE interval_start < toDateTime('${PROBE}') + INTERVAL 60 SECOND
               AND interval_end   >= toDateTime('${PROBE}')
             ORDER BY video_session_id LIMIT ${N_SESSIONS}) FORMAT TSVRaw")"
GOT=$(( $(printf '%s' "$LIST" | tr -cd ',' | wc -c) + 1 ))
say "claimed ${GOT} sessions covering the probe minute"

# The reader. One round trip returns the server clock plus all three tiers at
# the probe: minute-tier concurrency, hour-tier peak, user-tier distinct count.
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
poller() {
  while :; do
    q "$POLL_SQL" >> "$POLL" 2>/dev/null || true
  done
}

say "baseline (3 reads):"
for i in 1 2 3; do q "$POLL_SQL" | tee -a "$OUT"; done

poller & PPID_POLL=$!
trap 'kill $PPID_POLL 2>/dev/null || true' EXIT

say ""
say "publishing (forced, unchanged)…"
tools/publish.sh --database "$DB" --sessions "$LIST" 2>&1 | sed 's/^/  /' | tee -a "$OUT"

sleep 2
kill "$PPID_POLL" 2>/dev/null || true; wait "$PPID_POLL" 2>/dev/null || true
trap - EXIT

say ""
say "post-run (3 reads):"
for i in 1 2 3; do q "$POLL_SQL" | tee -a "$OUT"; done

say ""
say "poller samples: $(( $(wc -l < "$POLL") - 1 ))  ->  ${POLL}"
say ""
say "phase markers (cc_publish_runs, newest run):"
q "SELECT phase, at, rows_written, elapsed_ms FROM cc_publish_runs
   WHERE run_id = (SELECT max(run_id) FROM cc_publish_runs)
   ORDER BY at FORMAT PrettyCompact" | tee -a "$OUT"
