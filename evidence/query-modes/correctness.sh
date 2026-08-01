#!/usr/bin/env bash
# evidence/query-modes/correctness.sh — prove POINT and INTERVAL modes answer from
# the same truth. Runs against the single-generation scratch build (sonyliv_u3 by
# default; see capture.sh header for why not the graded db). READ-ONLY.
#
#   C1  the naive WITH FILL densify vs the minute spine — DOCUMENTS FINDING F1
#       (10 phantom minutes). Expected to differ; the count is the evidence.
#   C2  the hour-ANCHORED densify vs the minute spine — must agree everywhere
#   C3  point vs interval at 26 minutes — peak minute, both data boundaries,
#       held minutes, hour boundaries, an idle minute, and a spread. Three point
#       forms (hour-anchored delta sum, 1-min v_cc_window_range peak AND avg,
#       minute spine) must agree at every one
#   C4  every stored hour row vs the minute curve inside that hour (peak+integral)
#   C5  every day row vs the hour tier it rolls up (peak+integral)
#   C6  idle-minute semantics — "no row" vs "zero" — made explicit per path
#   C7  the un-anchored delta sum (the wrong way) — shown wrong on purpose
#   C8  F1's blast radius: does it reach the SERVING views, or only the recipe?
#
# Exit status is 0 only if every gate that is supposed to pass, passed.
set -euo pipefail
cd "$(dirname "$0")/../.."

QM_DATABASE="${QM_DATABASE:-sonyliv_u3}"
OUT=evidence/query-modes/correctness.txt
# The report is built inside a `| tee` pipeline, i.e. a SUBSHELL, so a failure
# flag set in there is lost to the exit check. Carry it in a file instead.
FLAG=$(mktemp); echo 0 > "$FLAG"
trap 'rm -f "$FLAG"' EXIT

q() { CH_DATABASE="$QM_DATABASE" TARGET=cloud tools/ch -c "$1"; }
# note_fail — record that a gate failed, from inside or outside the subshell
note_fail() { echo 1 > "$FLAG"; }

{
echo "# evidence/query-modes/correctness.txt — point vs interval, same truth"
echo "# database=${QM_DATABASE} (scratch, single generation, dev HEAD)  commit=$(git rev-parse --short HEAD)  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# READ-ONLY. Truth for the minute curve is v_cc_minute_series_total (the spine);"
echo "# truth independent of the delta model is v_concurrency_minute_intervals (session expansion)."
echo

echo "== C1: FINDING F1 — the naive WITH FILL densify vs the minute spine =="
echo "#  docs/CONVENTIONS.md's densify recipe, applied ACROSS hour boundaries."
echo "#  A nonzero count here is the DEFECT, not a regression: interpolation carries"
echo "#  a level into an hour that opened empty. Benchmark b06 fills ONE hour and is unaffected."
q "
WITH dense AS (
    SELECT minute, concurrent FROM v_concurrency_minute_delta_total
    ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
SELECT
    count()                                   AS minutes_compared,
    countIf(dense.concurrent != s.concurrent) AS phantom_minutes,
    uniqExactIf(toStartOfHour(dense.minute), dense.concurrent != s.concurrent) AS hours_affected,
    sumIf(dense.concurrent - s.concurrent, dense.concurrent != s.concurrent)   AS viewers_invented,
    maxIf(dense.concurrent - s.concurrent, dense.concurrent != s.concurrent)   AS worst_overstatement
FROM dense
INNER JOIN v_cc_minute_series_total AS s USING (minute)
FORMAT PrettyCompactMonoBlock"
echo "#  the affected minutes, with the independent interval-expansion truth alongside:"
q "
WITH dense AS (
    SELECT minute, concurrent FROM v_concurrency_minute_delta_total
    ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
SELECT dense.minute, dense.concurrent AS naive_fill, s.concurrent AS spine,
       ifNull(toString(t.concurrent), 'no row = 0') AS interval_expansion_truth
FROM dense
INNER JOIN v_cc_minute_series_total AS s USING (minute)
LEFT JOIN v_concurrency_minute_intervals AS t USING (minute)
WHERE dense.concurrent != s.concurrent
ORDER BY dense.minute
FORMAT PrettyCompactMonoBlock"
echo "#  why the build gate never saw it: it INNER JOINs the truth view, and these"
echo "#  minutes have no truth row to join to."
q "
WITH dense AS (
    SELECT minute, concurrent FROM v_concurrency_minute_delta_total
    ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
SELECT
  (SELECT countIf(dense.concurrent != i.concurrent)
     FROM dense INNER JOIN v_concurrency_minute_intervals i USING (minute)) AS inner_join_mismatches_the_gate_uses,
  (SELECT countIf(ifNull(dense.concurrent, 0) != ifNull(i.concurrent, 0))
     FROM dense FULL OUTER JOIN v_concurrency_minute_intervals i USING (minute)) AS full_outer_mismatches
FORMAT PrettyCompactMonoBlock"
echo

echo "== C2: the hour-ANCHORED densify vs the minute spine, whole data span =="
echo "#  the im06 recipe: every hour start gets an explicit 0-delta row. Must be 0 mismatches."
echo "#  Bounds are LITERAL because ClickHouse requires WITH FILL FROM/TO to be constant"
echo "#  (Code 475 on a scalar subquery); they are toStartOfHour(min(minute)) and"
echo "#  max(minute)+1min of cc_minute_delta on this build — asserted below before use."
q "SELECT if(toStartOfHour(min(minute)) = toDateTime('2026-07-14 15:00:00')
            AND max(minute) + INTERVAL 1 MINUTE = toDateTime('2026-07-26 11:33:00'),
            '   bounds assertion PASS', '   bounds assertion FAIL — literals below are stale')
   FROM cc_minute_delta FORMAT TSVRaw"
C2=$(q "
WITH
  toDateTime('2026-07-14 15:00:00') AS rs,
  toDateTime('2026-07-26 11:33:00') AS re,
  anchors AS (
     SELECT toDateTime(arrayJoin(range(toUInt32(rs), toUInt32(re), 3600))) AS minute, toInt64(0) AS d
  ),
  cps AS (
     SELECT minute, sum(delta) AS d FROM cc_minute_delta GROUP BY minute
  ),
  merged AS (
     SELECT minute, sum(d) AS d FROM (SELECT * FROM cps UNION ALL SELECT * FROM anchors) GROUP BY minute
  ),
  recipe AS (
    SELECT minute, concurrent FROM (
      SELECT minute, toInt64(sum(d) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent
      FROM merged
    ) ORDER BY minute ASC WITH FILL
        FROM toDateTime('2026-07-14 15:00:00') TO toDateTime('2026-07-26 11:33:00')
        STEP toIntervalMinute(1)
      INTERPOLATE (concurrent AS concurrent)
  )
SELECT concat(toString(count()), ' minutes compared, ',
              toString(countIf(recipe.concurrent != s.concurrent)), ' mismatched  ',
              if(countIf(recipe.concurrent != s.concurrent) = 0, 'PASS', 'FAIL'))
FROM recipe INNER JOIN v_cc_minute_series_total AS s USING (minute) FORMAT TSVRaw")
echo "$C2"
case "$C2" in *FAIL*) note_fail ;; esac
echo

echo "== C3: three point forms vs the 1-minute interval, at 26 chosen minutes =="
echo "#  m_direct = hour-anchored delta sum (pm02)   wr_peak/wr_avg = v_cc_window_range [M,M+1) (pm01)"
echo "#  spine = v_cc_minute_series_total lookup (— = no row)   all present values must be equal"
MINUTES="
2026-07-26 10:56:00|peak minute
2026-07-26 10:55:00|peak-1
2026-07-26 10:57:00|peak+1
2026-07-14 15:42:00|minute before first data
2026-07-14 15:43:00|FIRST data minute (boundary)
2026-07-14 15:44:00|held minute (no change point)
2026-07-26 11:31:00|LAST nonzero minute (boundary)
2026-07-26 11:32:00|last delta minute (level back to 0)
2026-07-26 11:33:00|after all data
2026-07-26 10:00:00|hour boundary inside data
2026-07-26 11:00:00|hour boundary inside data
2026-07-24 13:00:00|F1 hour start (naive fill says 1, truth 0)
2026-07-24 13:05:00|F1 mid-run
2026-07-20 03:30:00|IDLE minute (hour has no rows)
2026-07-15 06:00:00|spread
2026-07-16 12:30:00|spread
2026-07-17 20:15:00|spread
2026-07-18 04:44:00|spread
2026-07-19 09:07:00|spread
2026-07-21 23:59:00|spread
2026-07-22 07:13:00|spread
2026-07-23 14:26:00|spread
2026-07-25 10:56:00|spread
2026-07-26 08:30:00|busy morning
2026-07-26 10:30:00|busy morning
2026-07-26 11:15:00|busy morning"
printf '%-21s %9s %9s %9s %7s  %-7s %s\n' "minute" "m_direct" "wr_peak" "wr_avg" "spine" "verdict" "note"
while IFS='|' read -r M NOTE; do
  [ -n "$M" ] || continue
  LINE=$(q "
    WITH
      toDateTime('$M') AS m,
      (SELECT toInt64(sum(delta)) FROM cc_minute_delta
        WHERE minute >= toStartOfHour(m) AND minute <= m)               AS direct,
      (SELECT groupArray(toString(concurrent))
         FROM v_cc_minute_series_total WHERE minute = m)                AS spine_arr
    SELECT
      toString(direct),
      toString(w.peak),
      toString(toInt64(w.avg_concurrent)),
      if(length(spine_arr) = 0, '', spine_arr[1]),
      if(w.peak = direct
         AND toInt64(w.avg_concurrent) = direct
         AND (length(spine_arr) = 0 OR toInt64OrZero(spine_arr[1]) = direct),
         'PASS', 'FAIL')
    FROM v_cc_window_range(
        p_start = toDateTime('$M'),
        p_end   = toDateTime('$M') + INTERVAL 1 MINUTE,
        p_platform = '*', p_country = '*', p_content_id = -1) AS w
    FORMAT TSV" )
  D=$(echo "$LINE" | cut -f1); WP=$(echo "$LINE" | cut -f2); WA=$(echo "$LINE" | cut -f3)
  SP=$(echo "$LINE" | cut -f4); V=$(echo "$LINE" | cut -f5)
  [ "$V" = PASS ] || note_fail
  printf '%-21s %9s %9s %9s %7s  %-7s %s\n' "$M" "$D" "$WP" "$WA" "${SP:-—}" "$V" "$NOTE"
done <<< "$MINUTES"
echo

echo "== C4: every stored hour row (cube 0) vs the minute curve inside that hour =="
C4=$(q "
WITH per_hour AS (
    SELECT toStartOfHour(minute) AS hour, max(concurrent) AS peak_true, sum(concurrent) * 60 AS integral_true
    FROM v_cc_minute_series_total GROUP BY hour HAVING peak_true != 0 OR integral_true != 0
)
SELECT concat(toString(count()), ' hours compared, ',
              toString(countIf(h.peak != per_hour.peak_true)), ' peak / ',
              toString(countIf(h.integral != per_hour.integral_true)), ' integral mismatched  ',
              if(countIf(h.peak != per_hour.peak_true) + countIf(h.integral != per_hour.integral_true) = 0,
                 'PASS', 'FAIL'))
FROM per_hour FULL OUTER JOIN v_concurrency_hour_total AS h USING (hour) FORMAT TSVRaw")
echo "$C4"; case "$C4" in *FAIL*) note_fail ;; esac
echo

echo "== C5: every day row (cube 0) vs the hour tier it rolls up =="
C5=$(q "
WITH from_hours AS (
    SELECT toDate(hour) AS day, max(peak) AS peak_true, sum(integral) AS integral_true
    FROM v_concurrency_hour_total GROUP BY day
)
SELECT concat(toString(count()), ' days compared, ',
              toString(countIf(d.peak != from_hours.peak_true)), ' peak / ',
              toString(countIf(d.integral != from_hours.integral_true)), ' integral mismatched  ',
              if(countIf(d.peak != from_hours.peak_true) + countIf(d.integral != from_hours.integral_true) = 0,
                 'PASS', 'FAIL'))
FROM from_hours FULL OUTER JOIN v_concurrency_day_total AS d USING (day) FORMAT TSVRaw")
echo "$C5"; case "$C5" in *FAIL*) note_fail ;; esac
echo

echo "== C6: idle minute 2026-07-20 03:30 — what each path answers =="
echo "# hour-anchored delta sum (pm02) — sum over an empty set is 0, so this answers 0:"
q "SELECT toInt64(sum(delta)) AS concurrent FROM cc_minute_delta
   WHERE minute >= toStartOfHour(toDateTime('2026-07-20 03:30:00'))
     AND minute <= toDateTime('2026-07-20 03:30:00') FORMAT PrettyCompactMonoBlock"
echo "# 1-minute v_cc_window_range (pm01) — hrs=0 AND chg=0 is the 'no data in range' signature,"
echo "# which is how a caller tells a true 0 from an unanswerable minute. peak_minute is the"
echo "# documented epoch sentinel, NOT a real minute — read it only where peak > 0:"
q "SELECT peak, peak_minute, hours_from_hour_tier AS hrs, change_points_from_minute_tier AS chg
   FROM v_cc_window_range(p_start = toDateTime('2026-07-20 03:30:00'),
                          p_end   = toDateTime('2026-07-20 03:31:00'),
                          p_platform = '*', p_country = '*', p_content_id = -1)
   FORMAT PrettyCompactMonoBlock"
echo "# minute spine — 0 rows. The spine covers active hours + a 60-minute pad only,"
echo "# so ABSENCE is its answer for a long-idle minute. A caller must read absence as 0:"
q "SELECT count() AS spine_rows FROM v_cc_minute_series_total
   WHERE minute = toDateTime('2026-07-20 03:30:00') FORMAT PrettyCompactMonoBlock"
echo

echo "== C7: the WRONG way, shown wrong — delta sum NOT anchored at the hour start =="
echo "# sum(delta) over [10:30, 10:56] misses the level already standing at 10:29."
q "
SELECT
    (SELECT toInt64(sum(delta)) FROM cc_minute_delta
      WHERE minute >= toDateTime('2026-07-26 10:30:00')
        AND minute <= toDateTime('2026-07-26 10:56:00')) AS unanchored_looks_plausible,
    (SELECT toInt64(sum(delta)) FROM cc_minute_delta
      WHERE minute >= toStartOfHour(toDateTime('2026-07-26 10:56:00'))
        AND minute <= toDateTime('2026-07-26 10:56:00')) AS hour_anchored_truth
FORMAT PrettyCompactMonoBlock"
echo

echo "== C8: F1's blast radius — does the phantom reach the SERVING views? =="
echo "# The hour tier and the window-range view are built from the spine arithmetic,"
echo "# not from WITH FILL, so F1 must NOT appear in a served answer. Hour 13 on"
echo "# 2026-07-24: peak/integral from storage, and the 1-minute point answers."
C8=$(q "
SELECT concat(
  'hour row peak=', toString(h.peak), ' integral=', toString(h.integral),
  ' | point 13:00=', toString((SELECT peak FROM v_cc_window_range(
        p_start = toDateTime('2026-07-24 13:00:00'), p_end = toDateTime('2026-07-24 13:01:00'),
        p_platform='*', p_country='*', p_content_id=-1))),
  ' | point 13:05=', toString((SELECT peak FROM v_cc_window_range(
        p_start = toDateTime('2026-07-24 13:05:00'), p_end = toDateTime('2026-07-24 13:06:00'),
        p_platform='*', p_country='*', p_content_id=-1))),
  '  ', if(h.integral = 4440
           AND (SELECT peak FROM v_cc_window_range(
                  p_start = toDateTime('2026-07-24 13:00:00'), p_end = toDateTime('2026-07-24 13:01:00'),
                  p_platform='*', p_country='*', p_content_id=-1)) = 0,
           'PASS — serving layer is clean, F1 is a RECIPE defect only', 'FAIL — F1 reached storage'))
FROM v_concurrency_hour_total AS h WHERE h.hour = toDateTime('2026-07-24 13:00:00') FORMAT TSVRaw")
echo "$C8"; case "$C8" in *FAIL*) note_fail ;; esac
echo

echo "== VERDICT =="
if [ "$(cat "$FLAG")" = 0 ]; then
  echo "ALL GATES PASS (C1 is a documented defect count, not a gate)."
else
  echo "!! ONE OR MORE GATES FAILED — see above."
fi
} | tee "$OUT"

[ "$(cat "$FLAG")" = 0 ]
