#!/usr/bin/env bash
# ============================================================================
# evidence/publish-visibility/00-setup.sh — scratch DB for the Q29 experiment:
# can a reader observe a concurrency dip while a publish is in flight?
#
# Builds sonyliv_q29vis (own scratch database — NOT sonyliv_pub, which
# tools/publish-test.sh owns) with the full publication layer, loads the
# truncated slice (< CUT) from the graded database READ-ONLY, and bootstraps
# it through tools/publish.sh — the same path publish-test.sh proves.
#
# Writes: sonyliv_q29vis only. sonyliv is SELECTed from, never written.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && . ./.env && set +a

DB=sonyliv_q29vis
PROD=sonyliv                          # READ-ONLY
CUT="${CUT:-2026-07-26 10:56:00}"
OUT=evidence/publish-visibility/00-setup.txt

ch_host() { local h="${CH_HOST:?}"; h="${h#https://}"; h="${h#http://}"; echo "${h%/}"; }
q() {
  curl -sS --fail-with-body "https://$(ch_host):${CH_PORT}/" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"
}
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

# Refuse to run if this file writes to the graded database.
if grep -Eq "(INSERT[[:space:]]+INTO|TRUNCATE|DELETE[[:space:]]+FROM|DROP[[:space:]]+DATABASE)[[:space:]]+\\\$?\{?${PROD}\b" "$0"; then
  echo "REFUSING: $0 writes to ${PROD}" >&2; exit 1
fi

: > "$OUT"
say "Q29 publish-visibility — scratch setup"
say "generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')  ·  commit $(git rev-parse --short HEAD)"
say "db ${DB}  ·  slice < ${CUT}  ·  source ${PROD} (read-only)"

q "DROP DATABASE IF EXISTS ${DB}" >/dev/null
q "CREATE DATABASE ${DB}" >/dev/null
env -u CH_DATABASE TARGET=cloud tools/apply-sql.sh --database "$DB" \
  sql/00_schema.sql sql/10_intervals.sql sql/12_publish.sql sql/20_views.sql \
  sql/45_user_concurrency.sql sql/50_hour_agg.sql >/dev/null
say "schema applied (00, 10, 12, 20, 45, 50)"

q "INSERT INTO ${DB}.ev_raw
   SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
          platform, app_version, country, audio_language, subtitle_language,
          player_version, session_start_epoch
   FROM ${PROD}.ev_raw WHERE event_timestamp < toDateTime64('${CUT}', 3)" >/dev/null
say "loaded: $(q "SELECT concat(toString(count()), ' events · ', toString(uniqExact(video_session_id)), ' sessions') FROM ${DB}.ev_raw FORMAT TSVRaw")"

say "settling ${PUBLISH_SETTLE_S:-5}s, then bootstrap publish…"
sleep "$(( ${PUBLISH_SETTLE_S:-5} + 1 ))"
tools/publish.sh --database "$DB" 2>&1 | sed 's/^/  /' | tee -a "$OUT"

say ""
say "post-bootstrap lag:"
tools/publish.sh --database "$DB" --status 2>&1 | tee -a "$OUT"
