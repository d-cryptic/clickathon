#!/usr/bin/env bash
# ============================================================================
# tools/unseen-run.sh — THE UNSEEN-DAY RUN. One command, whole path, loud gate.
#
#   tools/unseen-run.sh <raw.csv> <content.csv|none>
#
# Runs the ENTIRE pipeline over a dataset we have never seen, in an ISOLATED
# database, and ends on the correctness gate:
#
#   reset -> schema -> load -> intervals -> user tier -> deltas -> views
#         -> hour agg -> content -> windows -> RECONCILE (truth from ev_raw)
#
# It does NOT reimplement any model SQL. Every statement is sed-templated out of
# the real sql/*.sql files (the technique tools/truncation-test.sh uses), so this
# script cannot drift from the model it is rehearsing. If sql/ changes, this
# changes with it.
#
# ISOLATION
#   Default target is the scratch database `sonyliv_unseen`. `sonyliv` is the
#   GRADED state: targeting it needs UNSEEN_ALLOW_PROD=1 typed on the command
#   line, on purpose. Nothing here reads production.
#
# FAIL LOUDLY
#   Every phase is asserted, not assumed: CSV header vs the loader's positional
#   column list, loaded rows == CSV data rows, every tier non-empty, and the gate
#   exits 1 on any mismatch. A failing phase prints a banner naming the phase and
#   stops. There is no "half-worked".
#
# THE GATE, on a day whose dates nobody knew in advance
#   sql/90_reconcile.sql hard-codes five minutes from 2026-07-26. Run unmodified
#   on any other day it returns ZERO ROWS — and tools/reconcile.sh greps for the
#   string MISMATCH, finds none, and reports PASS having compared nothing. So the
#   gate runs THREE ways here:
#     G0  the committed file, verbatim   -> exposes the vacuous pass
#     G1  five minutes DERIVED from the loaded day (peak, first, last, q25, q75)
#     G2  EVERY minute of the day, driven off the minute spine
#   G1 and G2 reuse the file's own truth derivation; only `targets` (and, for G2,
#   which side drives the final join) is templated.
#
# ENV
#   UNSEEN_DB=sonyliv_unseen   target database
#   UNSEEN_NO_RESET=1          do not drop the scratch database first (see RESET)
#   UNSEEN_ALLOW_PROD=1        permit UNSEEN_DB=sonyliv
#   UNSEEN_KEEP=1              keep the rendered SQL in the temp dir
#   UNSEEN_OUT=path            evidence file (default evidence/unseen-rehearsal.txt)
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
[ -f .env ] && set -a && . ./.env && set +a

RAW="${1:-}"
CONTENT="${2:-}"
DB="${UNSEEN_DB:-sonyliv_unseen}"
PROD="sonyliv"
OUT="${UNSEEN_OUT:-evidence/unseen-rehearsal.txt}"

TMP="$(mktemp -d)"; chmod 700 "$TMP"
cleanup() { [ -n "${UNSEEN_KEEP:-}" ] || rm -rf "$TMP"; }
trap cleanup EXIT

HOSTNAME_="${CH_HOST#https://}"; HOSTNAME_="${HOSTNAME_#http://}"; HOSTNAME_="${HOSTNAME_%/}"

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------
die() { printf '\n=== FAILED: %s ===\n%s\n' "${PHASE:-preflight}" "$*" | tee -a "$OUT" >&2; exit 1; }
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
rule(){ say "--------------------------------------------------------------------------"; }

# q <sql> — one statement over HTTPS, against $DB (NOT $CH_DATABASE).
q()  { curl -sS --fail-with-body "https://${HOSTNAME_}:${CH_PORT}/?database=${DB}" \
         --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"; }
q1() { q "$1 FORMAT TSVRaw" | tr -d '\n'; }
# qsys <sql> — server-level DDL. Must not connect through $DB: you cannot drop
# the database you are attached to.
qsys() { curl -sS --fail-with-body "https://${HOSTNAME_}:${CH_PORT}/?database=default" \
           --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$1"; }

# run_file <file> — multi-statement, native protocol via the `ch` container.
run_file() {
  assert_isolated "$1"
  docker exec -i -e CLICKHOUSE_PASSWORD="$CH_PASSWORD" ch clickhouse-client \
    --host "$HOSTNAME_" --port 9440 --secure --user "$CH_USER" \
    --database "$DB" --multiquery < "$1"
}

# A rendered file that still names another database would be silent and
# catastrophic. sql/80_content.sql hard-codes `sonyliv` in six dictGet calls and
# in the dictionary SOURCE, so this is not hypothetical.
assert_isolated() {
  if [ "$DB" != "$PROD" ] && grep -qE "(\bsonyliv\.|'sonyliv'|sonyliv_trunc)" "$1"; then
    die "rendered file $1 still names another database:
$(grep -nE "(\bsonyliv\.|'sonyliv'|sonyliv_trunc)" "$1")"
  fi
}

# render <src.sql> — templates the database name out of a real sql/ file and
# echoes the rendered path. Byte-identical to the committed file otherwise.
render() {
  local dst="$TMP/$(basename "$1")"
  sed -e "s/\bsonyliv\./${DB}./g" -e "s/'sonyliv'/'${DB}'/g" "$1" > "$dst"
  assert_isolated "$dst"
  printf '%s' "$dst"
}

PHASE=""
T_PHASE=0
T_TOTAL_START=$(date +%s)
TIMINGS=""
phase() {
  if [ -n "$PHASE" ]; then
    TIMINGS="${TIMINGS}$(printf '  %-58s %5ss' "$PHASE" "$(( $(date +%s) - T_PHASE ))")
"
  fi
  PHASE="$1"; T_PHASE=$(date +%s)
  say ""; rule; say "PHASE — $1"; rule
}
phase_end() {
  if [ -n "$PHASE" ]; then
    TIMINGS="${TIMINGS}$(printf '  %-58s %5ss' "$PHASE" "$(( $(date +%s) - T_PHASE ))")
"
  fi
  PHASE=""
}

# ---------------------------------------------------------------------------
# PREFLIGHT — every reason this run cannot start, before it starts
# ---------------------------------------------------------------------------
# ARGUMENTS FIRST — before $OUT is touched. An earlier version truncated the
# evidence file and *then* checked the arguments, so a mistyped command wiped a
# good run's evidence. Nothing writes to $OUT until the arguments are valid.
usage() { printf '%s\n' "$*" >&2; exit 2; }
[ -n "$RAW" ] || usage "usage: tools/unseen-run.sh <raw.csv> <content.csv|none>
The unseen day arrives as a CSV. Give it the CSV."
[ -f "$RAW" ] || usage "no such raw file: $RAW"
[ -n "$CONTENT" ] || usage "no content CSV given.
content_dim is EMPTY in a fresh database, and an empty dict_content does NOT
error — dictGet returns '' for every title/video_type/category, so the content
views silently serve blank dimensions. Pass the content CSV, or pass the literal
string 'none' to accept blank content dimensions knowingly."
[ "$CONTENT" = none ] || [ -f "$CONTENT" ] || usage "no such content file: $CONTENT"

mkdir -p evidence
: > "$OUT"
say "UNSEEN-DAY RUN"
say "generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')   commit $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
say "target database ${DB}   ·   raw ${RAW}   ·   content ${CONTENT}"
rule

if [ "$CONTENT" = none ]; then
  say "WARNING: no content CSV. dict_content will be empty and every"
  say "         v_concurrency_minute_{title,video_type,category} row carries a"
  say "         BLANK dimension. Accepted knowingly; 80_content.sql is skipped."
  CONTENT=""
fi

if [ "$DB" = "$PROD" ] && [ -z "${UNSEEN_ALLOW_PROD:-}" ]; then
  die "UNSEEN_DB=$PROD is the GRADED database and this script TRUNCATES tables.
Re-run with UNSEEN_ALLOW_PROD=1 if that is genuinely what you want."
fi

for v in CH_HOST CH_PORT CH_USER CH_PASSWORD; do
  [ -n "${!v:-}" ] || die "$v is unset — fill in .env"
done
docker inspect ch >/dev/null 2>&1 || die "the 'ch' docker container is not running.
Multi-statement SQL goes over the native protocol via that container's
clickhouse-client (same as tools/apply-sql.sh). Start it: docker compose up -d"
qsys "SELECT 1" >/dev/null || die "cannot reach ClickHouse at ${HOSTNAME_}:${CH_PORT}"

# RESET — this matters more than it looks.
#
# sql/00_schema.sql is all CREATE TABLE IF NOT EXISTS and tools/load.sh only
# APPENDS, so a second run over the same CSV does not replace the day, it adds
# it again. The schema comment claims otherwise:
#     "non_replicated_deduplication_window = 1000
#      Turn it on so a replayed batch is idempotent — the unseen day may be re-loaded."
# MEASURED on ClickHouse Cloud 26.2.1.525, 2026-08-01: loading the identical
# 30,097-row CSV twice left ev_raw at 60,194 rows, in two byte-identical parts
# (20260725_0_0_0 and 20260725_1_1_0, both 30,097 rows / 102,795 bytes on disk).
# Insert deduplication did NOT fire: that setting is for non-replicated MergeTree
# and the Cloud engine is SharedMergeTree. A re-load DOUBLES the day, silently.
#
# So a from-scratch run starts from scratch.
if [ "$DB" != "$PROD" ] && [ -z "${UNSEEN_NO_RESET:-}" ]; then
  say "reset: DROP DATABASE ${DB} — re-loading without this DOUBLES ev_raw (measured; see the note in this script)"
  qsys "DROP DATABASE IF EXISTS ${DB}" >/dev/null
fi
qsys "CREATE DATABASE IF NOT EXISTS ${DB}" >/dev/null
if [ "$(q1 "SELECT count() FROM system.tables WHERE database='${DB}' AND name='ev_raw'")" != "0" ]; then
  PRELOADED=$(q1 "SELECT count() FROM ev_raw")
  [ "$PRELOADED" = "0" ] || die "${DB}.ev_raw already holds ${PRELOADED} rows and this run would APPEND.
tools/load.sh only appends and Cloud insert-dedup does not fire (measured), so
the day would be counted twice. Drop the database, or unset UNSEEN_NO_RESET."
fi
say "preflight ok · server $(q1 "SELECT version()") · database ${DB} ready and empty"

# CSV shape. A changed header on a new day is the single likeliest surprise, and
# load.sh maps columns POSITIONALLY through input(...), so a reordered, renamed
# or extended header loads garbage without erroring. Quoting is a CSV detail
# (CSVWithNames accepts either), so normalise that but compare everything else.
EXPECTED_HDR='content_id,video_session_id,user_id,event_type,event,event_timestamp,platform,app_version,country,audio_language,subtitle_language,player_version,session_start_epoch'
ACTUAL_HDR="$(head -1 "$RAW" | tr -d '\r"' | tr -d ' ')"
if [ "$ACTUAL_HDR" != "$EXPECTED_HDR" ]; then
  die "raw CSV header does not match what tools/load.sh inserts.
expected: $EXPECTED_HDR
actual  : $ACTUAL_HDR
Columns are mapped by POSITION, not by name. Fix the loader before continuing."
fi
CSV_ROWS=$(( $(wc -l < "$RAW") - 1 ))
say "raw CSV header matches the loader · ${CSV_ROWS} data rows"

# FINGERPRINT. sql/ is edited by other people while this runs — it was, during
# the 2026-08-01 rehearsal (10/30/40 gained four dimensions mid-run). Evidence
# that does not name the revision it tested is not evidence.
say ""
say "SQL fingerprint (sha256, first 12) — the exact model this run exercised:"
for f in sql/00_schema.sql sql/10_intervals.sql sql/20_views.sql sql/30_build_intervals.sql \
         sql/40_deltas.sql sql/45_user_concurrency.sql sql/50_hour_agg.sql \
         sql/80_content.sql sql/85_windows.sql sql/90_reconcile.sql tools/load.sh; do
  say "  $(shasum -a 256 "$f" | cut -c1-12)  $f"
done
say "  git $(git rev-parse --short HEAD 2>/dev/null || echo n/a) $(git diff --quiet -- sql tools 2>/dev/null && echo '(sql+tools clean)' || echo '(sql+tools DIRTY — uncommitted changes)')"

# ---------------------------------------------------------------------------
phase "1 schema (00_schema, 10_intervals) — tables + the stateless MV"
# Order is not optional: mv_stateless is the ONLY populator of
# cc_minute_stateless — there is no backfill anywhere in sql/. Create it after
# the load and that whole comparison deliverable is silently empty.
run_file "$(render sql/00_schema.sql)"
run_file "$(render sql/10_intervals.sql)"
say "  objects: $(q1 "SELECT count() FROM system.tables WHERE database='${DB}'") created"

# ---------------------------------------------------------------------------
phase "2 load (tools/load.sh, unmodified)"
# tools/load.sh now takes its database from --database first, then the
# ENVIRONMENT, then ./.env (it is still the only tool that does NOT cd to the
# repo root, so ./.env means the sandbox's copy). All three are set to $DB here
# and they must agree: this script exports CH_DATABASE=sonyliv by sourcing the
# repo .env at line 50, and load.sh dies rather than resolve a --database that
# contradicts an exported CH_DATABASE. The sandbox .env stays as the third,
# redundant belt — if either of the first two is ever dropped, the load still
# cannot wander into production.
SANDBOX="$TMP/sandbox"; mkdir -p "$SANDBOX"; chmod 700 "$SANDBOX"
sed "s|^CH_DATABASE=.*|CH_DATABASE=${DB}|" "$REPO/.env" > "$SANDBOX/.env"
chmod 600 "$SANDBOX/.env"
grep -q "^CH_DATABASE=${DB}$" "$SANDBOX/.env" || die "could not override CH_DATABASE in the sandbox .env.
Without that override tools/load.sh would load into ${PROD}. Refusing to run."
RAW_ABS="$(cd "$(dirname "$RAW")" && pwd)/$(basename "$RAW")"
CONTENT_ABS="/dev/null"
[ -n "$CONTENT" ] && CONTENT_ABS="$(cd "$(dirname "$CONTENT")" && pwd)/$(basename "$CONTENT")"
( cd "$SANDBOX" && CH_DATABASE="$DB" TARGET=cloud \
    "$REPO/tools/load.sh" --database "$DB" "$RAW_ABS" "$CONTENT_ABS" ) | tee -a "$OUT"

EV=$(q1 "SELECT count() FROM ev_raw")
[ "$EV" = "$CSV_ROWS" ] || die "ev_raw holds $EV rows, the CSV has $CSV_ROWS data rows.
A partial or doubled load is worse than no load: every downstream number would
be plausible and wrong."
say "  ev_raw $EV = CSV data rows $CSV_ROWS"
say "  $(q1 "SELECT concat(toString(uniqExact(video_session_id)),' sessions · ',
        toString(uniqExact(user_id)),' users · ',toString(uniqExact(content_id)),' content ids · ',
        toString(min(event_timestamp)),' -> ',toString(max(event_timestamp))) FROM ev_raw")"
say "  content_dim $(q1 "SELECT count() FROM content_dim") rows"
STL=$(q1 "SELECT count() FROM cc_minute_stateless")
[ "$STL" -gt 0 ] || die "cc_minute_stateless is EMPTY after the load — mv_stateless did not fire.
It is the only populator; there is no backfill. Schema must precede the load."
say "  cc_minute_stateless $STL rows (mv_stateless fired during the load)"

# The day under test, derived from the data. Never assumed, never hard-coded.
DAY_MIN=$(q1 "SELECT toString(toStartOfMinute(min(event_timestamp))) FROM ev_raw")
DAY_MAX=$(q1 "SELECT toString(toStartOfMinute(max(event_timestamp))) FROM ev_raw")
NDAYS=$(q1  "SELECT uniqExact(toDate(event_timestamp)) FROM ev_raw")
say "  data spans ${DAY_MIN} .. ${DAY_MAX}  (${NDAYS} calendar day(s))"

# ---------------------------------------------------------------------------
phase "3 intervals (30_build_intervals.sql)"
q "TRUNCATE TABLE session_intervals" >/dev/null
run_file "$(render sql/30_build_intervals.sql)"
IV=$(q1 "SELECT count() FROM session_intervals FINAL")
[ "$IV" -gt 0 ] || die "session_intervals is empty — the derivation produced nothing."
say "  $(q1 "SELECT concat(toString(count()),' intervals over ',
        toString(uniqExact(video_session_id)),' sessions · ',
        toString(countIf(is_open=1)),' still open · ',
        toString(round(sum(dateDiff('second',interval_start,interval_end))/3600,1)),
        ' active hours') FROM session_intervals FINAL")"

# ---------------------------------------------------------------------------
phase "4 user tier (45_user_concurrency.sql)"
run_file "$(render sql/45_user_concurrency.sql)"
say "  cc_user_minute $(q1 "SELECT count() FROM cc_user_minute") rows"

# ---------------------------------------------------------------------------
phase "5 deltas (40_deltas.sql)"
# cc_minute_delta is an AggregatingMergeTree of SUMS: a second insert without a
# TRUNCATE silently doubles every number, and the result looks plausible.
q "TRUNCATE TABLE cc_minute_delta" >/dev/null
run_file "$(render sql/40_deltas.sql)"
CD=$(q1 "SELECT count() FROM cc_minute_delta")
[ "$CD" -gt 0 ] || die "cc_minute_delta is empty."
say "  $(q1 "SELECT concat(toString(count()),' delta rows · opens ',toString(sum(starts)),
        ' · closes ',toString(sum(ends))) FROM cc_minute_delta")"

# ---------------------------------------------------------------------------
phase "6 views (20) + hour agg (50) + content (80) + windows (85)"
run_file "$(render sql/20_views.sql)"
run_file "$(render sql/50_hour_agg.sql)"
[ -n "$CONTENT" ] && run_file "$(render sql/80_content.sql)"
run_file "$(render sql/85_windows.sql)"
say "  cc_hour_agg $(q1 "SELECT count() FROM cc_hour_agg FINAL") rows"
say "  $(q1 "SELECT concat('hour tier says peak ',toString(max(peak)),' @ ',
        toString(argMax(peak_minute,peak))) FROM cc_hour_agg FINAL
        WHERE platform='*' AND country='*' AND content_id=-1")"

# ---------------------------------------------------------------------------
phase "7 the answer (this is what we would submit)"
PEAK_MIN=$(q1 "SELECT toString(argMax(minute, concurrent)) FROM v_concurrency_minute_delta_total")
PEAK_VAL=$(q1 "SELECT toString(max(concurrent)) FROM v_concurrency_minute_delta_total")
say "  session concurrency  peak ${PEAK_VAL} @ ${PEAK_MIN}"
say "  user concurrency     peak $(q1 "SELECT toString(max(concurrent_users)) FROM v_user_concurrency_minute_total")"
say "  stateless baseline   peak $(q1 "SELECT toString(max(concurrent)) FROM v_concurrency_minute_total")"
# Ties are not academic: on 2026-07-25 four minutes share the peak and the
# minute tier and the hour tier name DIFFERENT ones. If the ground truth asks
# "which minute", say which rule you used.
say "  minutes tied at the peak: $(q1 "SELECT toString(count()) FROM v_concurrency_minute_delta_total
        WHERE concurrent = (SELECT max(concurrent) FROM v_concurrency_minute_delta_total)")"

# ---------------------------------------------------------------------------
phase "8 THE GATE — truth recomputed from ev_raw"
G0="$(render sql/90_reconcile.sql)"

# G0 — the committed gate, verbatim.
G0_OUT="$(run_file "$G0" || true)"
G0_ROWS=$(printf '%s' "$G0_OUT" | grep -c . || true)
say ""
say "G0 — sql/90_reconcile.sql VERBATIM (its five target minutes are 2026-07-26 literals):"
if [ "$G0_ROWS" -eq 0 ]; then
  say "     ZERO ROWS. It compared nothing. tools/reconcile.sh greps the output for"
  say "     the string MISMATCH, finds none, and reports PASS — a VACUOUS PASS."
  VACUOUS=yes
else
  say "$(printf '%s' "$G0_OUT" | sed 's/^/     /')"
  VACUOUS=no
fi

# G1 — the same file, `targets` swapped for five minutes DERIVED from this day.
Q25=$(q1 "SELECT toString(quantileExact(0.25)(minute)) FROM (SELECT DISTINCT toStartOfMinute(event_timestamp) AS minute FROM ev_raw)")
Q75=$(q1 "SELECT toString(quantileExact(0.75)(minute)) FROM (SELECT DISTINCT toStartOfMinute(event_timestamp) AS minute FROM ev_raw)")
say ""
say "G1 — same gate, five minutes DERIVED from the loaded day:"
say "     peak ${PEAK_MIN} · first ${DAY_MIN} · last ${DAY_MAX} · q25 ${Q25} · q75 ${Q75}"
TARGETS="toDateTime('${PEAK_MIN}'),toDateTime('${DAY_MIN}'),toDateTime('${DAY_MAX}'),toDateTime('${Q25}'),toDateTime('${Q75}')"
perl -0pe "s/SELECT arrayJoin\(\[.*?\]\) AS m/SELECT arrayJoin([${TARGETS}]) AS m/s" "$G0" > "$TMP/g1.sql"
grep -q "$PEAK_MIN" "$TMP/g1.sql" || die "could not template the target minutes into the gate"
G1_OUT="$(run_file "$TMP/g1.sql")"
say "$(printf '%s' "$G1_OUT" | sed 's/^/     /')"

# G2 — EVERY minute, and driven off `targets` rather than off `truth`.
#
# That second change is not cosmetic. sql/90_reconcile.sql ends with
#     FROM truth AS t LEFT JOIN served AS s
# and `truth` is a GROUP BY over a CROSS JOIN, so a minute in which NOBODY was
# watching produces no row at all — it is never compared, whatever the serving
# layer claims about it. MEASURED on this database, 2026-08-01: injecting
#     INSERT INTO cc_minute_delta (minute,platform,country,content_id,delta,starts,ends)
#     SELECT toDateTime('2026-07-25 00:44:00'),'ANDROID_PHONE','india',12345,500,500,0
# made v_concurrency_minute_delta_total report 500 concurrent viewers at an idle
# minute, and BOTH the five-minute gate and a truth-driven all-minutes gate still
# said PASS. Driving off the minute spine closes it.
say ""
say "G2 — same gate over EVERY minute ${DAY_MIN} .. ${DAY_MAX}, driven off the minute"
say "     spine so IDLE minutes are compared too (the truth-driven form skips them):"
ALLMIN="SELECT toDateTime(arrayJoin(range(toUInt32(toDateTime('${DAY_MIN}')), toUInt32(toDateTime('${DAY_MAX}'))+60, 60))) AS m"
perl -0pe "s/SELECT arrayJoin\(\[.*?\]\) AS m/${ALLMIN}/s" "$G0" > "$TMP/g2_body.sql"
perl -0pe "s/SELECT\s*\n\s*t\.minute\s+AS minute,.*\z/SELECT
    count()                                          AS minutes_compared,
    countIf(ifNull(t.truth,0) = 0)                   AS of_which_idle,
    countIf(ifNull(s.served,0) != ifNull(t.truth,0)) AS mismatches,
    max(abs(ifNull(s.served,0) - ifNull(t.truth,0))) AS max_abs_diff,
    max(ifNull(t.truth,0))                           AS peak_truth,
    if(countIf(ifNull(s.served,0) != ifNull(t.truth,0)) = 0, 'PASS', 'MISMATCH') AS verdict
FROM targets AS tg
LEFT JOIN truth  AS t ON t.minute = tg.m
LEFT JOIN served AS s ON s.minute = tg.m;
/s" "$TMP/g2_body.sql" > "$TMP/g2.sql"
G2_OUT="$(run_file "$TMP/g2.sql")"
say "$(printf '%s' "$G2_OUT" | sed 's/^/     /')"

phase_end

# ---------------------------------------------------------------------------
say ""
rule
say "TIMINGS — wall clock, this run, ${CSV_ROWS} events"
rule
printf '%s' "$TIMINGS" | tee -a "$OUT"
say "$(printf '  %-58s %5ss' 'TOTAL' "$(( $(date +%s) - T_TOTAL_START ))")"

FAILED=no
printf '%s' "$G1_OUT" | grep -q MISMATCH && FAILED=yes
printf '%s' "$G2_OUT" | grep -q MISMATCH && FAILED=yes
say ""
rule
if [ "$FAILED" = yes ]; then
  say "VERDICT — GATE FAILED. The serving layer disagrees with ev_raw. Do not submit."
  rule
  echo "unseen run FAILED · $OUT" >&2
  exit 1
fi
say "VERDICT — GATE PASSED on ${DB}. peak ${PEAK_VAL} @ ${PEAK_MIN}."
if [ "$VACUOUS" = yes ]; then
  say "         WARNING: the committed gate (G0) passed VACUOUSLY — it compared zero"
  say "         minutes. Only G1 and G2 tested anything. sql/90_reconcile.sql must be"
  say "         re-targeted before tools/reconcile.sh means anything on this day."
fi
rule
echo
echo "unseen run PASSED · evidence written to $OUT"
