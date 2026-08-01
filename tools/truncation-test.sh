#!/usr/bin/env bash
# ============================================================================
# tools/truncation-test.sh — H4/H8. Open-session absorption + late arrival.
#
# Cuts the stream mid-event at the global peak, builds the model on the stump,
# then absorbs the remainder INCREMENTALLY (ADR 0006 correction-by-diff) and
# asks whether that converges on the from-scratch answer.
#
# ISOLATION: everything writes to `sonyliv_trunc`. `sonyliv` is read with
# SELECT only. Every statement is database-qualified and assert_isolated()
# refuses to run any templated file that names production as a write target.
# Do not "simplify" the qualification away.
#
# The derivation SQL is NOT reimplemented here. It is sed-templated out of
# sql/30_build_intervals.sql and sql/40_deltas.sql, so the test can never drift
# from the model it is testing — if those change, this changes with them.
#
#   tools/truncation-test.sh        # full run, writes evidence/truncation.txt
#
# Prereq: TARGET=cloud tools/apply-sql.sh sql/70_truncation_test.sql
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

CUT="${CUT:-2026-07-26 10:56:00}"
DB=sonyliv_trunc
PROD=sonyliv                    # READ-ONLY. Never a write target.
OUT=evidence/truncation.txt
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

HOSTNAME_="${CH_HOST#https://}"; HOSTNAME_="${HOSTNAME_#http://}"; HOSTNAME_="${HOSTNAME_%/}"

q()    { tools/ch -c "$1"; }
qr()   { tools/ch -c "$1 FORMAT TSVRaw"; }
say()  { printf '%s\n' "$*" | tee -a "$OUT"; }
rule() { say "--------------------------------------------------------------------------"; }

# A typo pointing a build at production would be silent and catastrophic.
assert_isolated() {
  if grep -Eiq "(INSERT[[:space:]]+INTO|TRUNCATE[[:space:]]+TABLE)[[:space:]]+${PROD}\." "$1"; then
    echo "REFUSING: $1 writes to ${PROD}" >&2; exit 1
  fi
}

run_file() {
  assert_isolated "$1"
  docker exec -i -e CLICKHOUSE_PASSWORD="$CH_PASSWORD" ch clickhouse-client \
    --host "$HOSTNAME_" --port 9440 --secure --user "$CH_USER" \
    --database "$DB" --multiquery < "$1"
}

# build_intervals <target> <source> [where]
build_intervals() {
  sed -e "s|^INSERT INTO session_intervals|INSERT INTO $1|" \
      -e "s|^        FROM ev_raw\$|        FROM $2 ${3:-}|" \
      sql/30_build_intervals.sql > "$TMP/bi.sql"
  run_file "$TMP/bi.sql"
}

# build_deltas <target> <source> <FINAL|""> [where] [+|-]
# sign '-' emits the NEGATION of the derivation — ADR 0006 step 3.
build_deltas() {
  local d="    sum(d)  AS delta," s="    sum(op) AS starts," e="    sum(cl) AS ends"
  if [ "${5:-+}" = "-" ]; then
    # starts/ends are SimpleAggregateFunction(sum, UInt64) and CANNOT carry a
    # negative correction (it wraps). Only `delta` (Int64) is correctable, so
    # the corrective row zeroes the other two. See the FINDING in the output.
    d="    -sum(d) AS delta,"; s="    toUInt64(0) AS starts,"; e="    toUInt64(0) AS ends"
  fi
  sed -e "s|^INSERT INTO cc_minute_delta|INSERT INTO $1|" \
      -e "s|^    FROM session_intervals FINAL\$|    FROM $2 $3 ${4:-}|" \
      -e "s|^    sum(d)  AS delta,\$|$d|" \
      -e "s|^    sum(op) AS starts,\$|$s|" \
      -e "s|^    sum(cl) AS ends\$|$e|" \
      sql/40_deltas.sql > "$TMP/bd.sql"
  run_file "$TMP/bd.sql"
}

# cc <db> <table> <minute> — concurrency off the hour-clipped running sum.
# Robust to a minute owning no delta row, which the change-only view is not.
cc() {
  q "SELECT toInt64(sum(delta)) FROM $1.$2
     WHERE minute >= toStartOfHour(toDateTime('$3')) AND minute <= toDateTime('$3') FORMAT TSV"
}

: > "$OUT"
say "TRUNCATION / OPEN-SESSION ABSORPTION TEST   (TODOS H4 + H8)"
say "generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "cut ${CUT}  ·  isolated database ${DB}  ·  ${PROD} read-only"
rule

say "PHASE 0 — reset the test database (never touches ${PROD})"
for t in ev_raw session_intervals session_intervals_prev cc_minute_delta \
         cc_minute_delta_stump session_intervals_control cc_minute_delta_control; do
  q "TRUNCATE TABLE ${DB}.${t}" >/dev/null
done

say ""
say "PHASE 1 — load the truncated slice: event_timestamp < ${CUT}"
q "INSERT INTO ${DB}.ev_raw
   SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
          platform, app_version, country, audio_language, subtitle_language,
          player_version, session_start_epoch
   FROM ${PROD}.ev_raw WHERE event_timestamp < toDateTime64('${CUT}', 3)"
say "  $(qr "SELECT concat(toString(count()),' events · ',toString(uniqExact(video_session_id)),
              ' sessions · last event ', toString(max(event_timestamp))) FROM ${DB}.ev_raw")"
say "  $(qr "SELECT concat('withheld: ', toString(count()),' events · ',
              toString(uniqExact(video_session_id)),' sessions touched')
            FROM ${PROD}.ev_raw WHERE event_timestamp >= toDateTime64('${CUT}',3)")"

say ""
say "PHASE 2 — build the model on the stump (this is what the dashboard served at ${CUT})"
build_intervals "${DB}.session_intervals" "${DB}.ev_raw"
build_deltas    "${DB}.cc_minute_delta" "${DB}.session_intervals" "FINAL"
q "INSERT INTO ${DB}.cc_minute_delta_stump SELECT * FROM ${DB}.cc_minute_delta"
say "  $(qr "SELECT concat(toString(count()),' intervals · is_open=1 on ',
              toString(countIf(is_open=1)),' intervals over ',
              toString(uniqExactIf(video_session_id, is_open=1)),' sessions (',
              toString(round(100*uniqExactIf(video_session_id,is_open=1)/uniqExact(video_session_id),1)),
              '% of sessions in the slice)')
            FROM ${DB}.session_intervals FINAL")"
say "  stump concurrency  @10:56 = $(cc $DB cc_minute_delta '2026-07-26 10:56:00')" \
    " @11:10 = $(cc $DB cc_minute_delta '2026-07-26 11:10:00')"

say ""
say "PHASE 3 — the late arrival: insert every event >= ${CUT}"
q "INSERT INTO ${DB}.ev_raw
   SELECT content_id, video_session_id, user_id, event_type, event, event_timestamp,
          platform, app_version, country, audio_language, subtitle_language,
          player_version, session_start_epoch
   FROM ${PROD}.ev_raw WHERE event_timestamp >= toDateTime64('${CUT}', 3)"

TOUCHED="WHERE video_session_id IN (SELECT video_session_id FROM ${DB}.ev_raw WHERE event_timestamp >= toDateTime64('${CUT}',3))"

say ""
say "PHASE 4 — absorb INCREMENTALLY (ADR 0006). cc_minute_delta is never truncated,"
say "          never mutated, never rebuilt. Only appended to."
say "  4a  snapshot the OLD derivation for the touched sessions"
q "INSERT INTO ${DB}.session_intervals_prev
   SELECT video_session_id, user_id, content_id, platform, country,
          interval_start, interval_end, is_open
   FROM ${DB}.session_intervals FINAL ${TOUCHED}"
say "      $(qr "SELECT concat(toString(count()),' old intervals over ',
                  toString(uniqExact(video_session_id)),' sessions')
                FROM ${DB}.session_intervals_prev")"

say "  4b  append the NEGATION of their deltas"
build_deltas "${DB}.cc_minute_delta" "${DB}.session_intervals_prev" "" "" "-"

say "  4c  re-derive ONLY the touched sessions (ReplacingMergeTree takes the new versions)"
build_intervals "${DB}.session_intervals" "${DB}.ev_raw" "$TOUCHED"

say "  4d  append the new deltas for those sessions"
build_deltas "${DB}.cc_minute_delta" "${DB}.session_intervals" "FINAL" "$TOUCHED" "+"
say "      $(qr "SELECT concat('cc_minute_delta now holds ',toString(count()),' rows, ',
                  toString(countIf(delta<0)),' of them negative corrections')
                FROM ${DB}.cc_minute_delta")"

say ""
say "PHASE 5 — control: from-scratch full build over the same complete stream"
build_intervals "${DB}.session_intervals_control" "${DB}.ev_raw"
build_deltas    "${DB}.cc_minute_delta_control" "${DB}.session_intervals_control" "FINAL"

say ""
rule
say "RESULT — concurrency at the two probe minutes"
rule
printf '%-34s %10s %10s\n' "" "10:56" "11:10" | tee -a "$OUT"
printf '%-34s %10s %10s\n' "truncated (stump, pre-absorption)" \
  "$(cc $DB cc_minute_delta_stump '2026-07-26 10:56:00')" \
  "$(cc $DB cc_minute_delta_stump '2026-07-26 11:10:00')" | tee -a "$OUT"
printf '%-34s %10s %10s\n' "after INCREMENTAL absorption" \
  "$(cc $DB cc_minute_delta '2026-07-26 10:56:00')" \
  "$(cc $DB cc_minute_delta '2026-07-26 11:10:00')" | tee -a "$OUT"
printf '%-34s %10s %10s\n' "control: from-scratch full build" \
  "$(cc $DB cc_minute_delta_control '2026-07-26 10:56:00')" \
  "$(cc $DB cc_minute_delta_control '2026-07-26 11:10:00')" | tee -a "$OUT"
printf '%-34s %10s %10s\n' "production truth (${PROD})" \
  "$(cc $PROD cc_minute_delta '2026-07-26 10:56:00')" \
  "$(cc $PROD cc_minute_delta '2026-07-26 11:10:00')" | tee -a "$OUT"

say ""
rule
say "CONVERGENCE over EVERY minute — spot checks prove nothing"
rule
say "$(qr "
WITH inc AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total),
     ctl AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total_control)
SELECT if(countIf(inc.concurrent != ctl.concurrent) = 0,
  concat('CONVERGES  incremental == control on all ',toString(count()),' minutes · peak ',
         toString(max(ctl.concurrent))),
  concat('DIVERGES   ',toString(countIf(inc.concurrent != ctl.concurrent)),' of ',
         toString(count()),' minutes differ · max |diff| ',
         toString(max(abs(inc.concurrent - ctl.concurrent)))))
FROM inc FULL OUTER JOIN ctl USING (minute)")"
say "$(qr "
WITH inc AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total),
     prd AS (SELECT minute, concurrent FROM ${PROD}.v_concurrency_minute_delta_total)
SELECT if(countIf(inc.concurrent != prd.concurrent) = 0,
  concat('CONVERGES  incremental == production truth on all ',toString(count()),' minutes'),
  concat('DIVERGES   ',toString(countIf(inc.concurrent != prd.concurrent)),' of ',
         toString(count()),' minutes differ · max |diff| ',
         toString(max(abs(inc.concurrent - prd.concurrent)))))
FROM inc FULL OUTER JOIN prd USING (minute)")"
say "$(qr "
SELECT if(countIf(a.interval_end != b.interval_end OR a.is_open != b.is_open) = 0 AND
          (SELECT count() FROM ${DB}.session_intervals FINAL) =
          (SELECT count() FROM ${DB}.session_intervals_control FINAL),
  'CONVERGES  session_intervals identical to a clean rebuild, row for row',
  concat('DIVERGES   incremental holds ',
         toString((SELECT count() FROM ${DB}.session_intervals FINAL)),
         ' intervals vs ',
         toString((SELECT count() FROM ${DB}.session_intervals_control FINAL)),
         ' in the clean rebuild · ',
         toString(countIf(a.interval_end != b.interval_end)),' shared keys disagree on interval_end'))
FROM ${DB}.session_intervals FINAL a
FULL OUTER JOIN ${DB}.session_intervals_control FINAL b
  USING (video_session_id, interval_start)")"

say ""
rule
say "WATERMARK — how far BACK from the cut did truncation corrupt the answer?"
say "(measured, not guessed: ADR 0004 requires W be set from the data)"
rule
say "$(qr "
WITH s AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total_stump),
     c AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total_control)
SELECT concat('earliest corrupted minute ', toString(min(s.minute)),
              ' · that is ', toString(dateDiff('second', min(s.minute), toDateTime('${CUT}'))),
              ' s before the cut · ',
              toString(count()),' minutes were wrong in the stump')
FROM s INNER JOIN c USING (minute) WHERE s.concurrent != c.concurrent")"
say ""
say "  minutes leading up to the cut — stump vs truth:"
say "$(q "
WITH s AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total_stump),
     c AS (SELECT minute, concurrent FROM ${DB}.v_concurrency_minute_delta_total_control)
SELECT s.minute AS minute, s.concurrent AS stump, c.concurrent AS truth,
       s.concurrent - c.concurrent AS diff
FROM s INNER JOIN c USING (minute)
WHERE minute BETWEEN toDateTime('${CUT}') - INTERVAL 40 MINUTE AND toDateTime('${CUT}')
ORDER BY minute FORMAT PrettyCompactMonoBlock")"

echo; echo "wrote $OUT"
