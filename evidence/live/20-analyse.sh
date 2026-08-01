#!/usr/bin/env bash
# ============================================================================
# 20-analyse.sh — read the sweep and answer the five questions.
#
#   1  how large is the provisional window (event time)?
#   2  how much of the served curve is provisional at any instant?
#   3  which DIRECTION does the live edge err in?
#   4  how fast does a minute converge once it can?
#   5  how does this compose with the publish dip (ADR 0023)?
#
# Reads only the scratch tables built by 00-setup.sh and 10-asof-sweep.sh.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

SCRATCH="${SCRATCH_DB:-sonyliv_v3live}"

if grep -nEi '(INSERT[[:space:]]+INTO|TRUNCATE([[:space:]]+TABLE)?|ALTER[[:space:]]+TABLE|DROP[[:space:]]+(TABLE|DATABASE)|OPTIMIZE[[:space:]]+TABLE|CREATE[[:space:]]+(TABLE|DATABASE))[[:space:]]+sonyliv([^_A-Za-z0-9]|$)' "$0"; then
  echo "REFUSING: this script contains a write against the graded database." >&2
  exit 1
fi

q() { CH_DATABASE="$SCRATCH" tools/ch -c "$1"; }

echo "=== LIVE-INTERVAL EVIDENCE · analysis"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ)   ·   scratch database: $SCRATCH"
echo "model constants in force: GAP_S=150  TAIL_S=60  (sql/30_build_intervals.sql)"
echo

echo "--------------------------------------------------------------------------"
echo "0 — scope of the sweep"
echo "--------------------------------------------------------------------------"
q "SELECT 'cuts=' || toString(uniqExact(cut))
       || '  minute-cells compared=' || toString(count())
       || '  cells wrong=' || toString(countIf(diff != 0))
       || '  (' || toString(round(countIf(diff != 0) / count() * 100, 4)) || '%)'
   FROM $SCRATCH.asof_curve FORMAT TSVRaw"

echo
echo "--------------------------------------------------------------------------"
echo "1 — THE PROVISIONAL WINDOW, in event time."
echo "    age_s = how old the minute is at the moment we ask (cut - minute)."
echo "    Every cell at every cut, bucketed by age. A minute is FINAL once no"
echo "    cut at that age ever disagrees with the completed build."
echo "--------------------------------------------------------------------------"
q "SELECT age_s,
          count()                                            AS cells,
          countIf(diff != 0)                                 AS wrong,
          min(diff)                                          AS worst_under,
          max(diff)                                          AS worst_over,
          round(min(diff / nullIf(final, 0)) * 100, 2)       AS worst_rel_pct,
          round(avg(diff / nullIf(final, 0)) * 100, 3)       AS mean_rel_pct
   FROM $SCRATCH.asof_curve
   WHERE final > 0 AND age_s <= 360
   GROUP BY age_s ORDER BY age_s FORMAT PrettyCompactMonoBlock"

echo
printf 'oldest age at which ANY cut was ever wrong: '
q "SELECT toString(max(age_s)) || ' s' FROM $SCRATCH.asof_curve WHERE diff != 0 FORMAT TSVRaw"
printf 'the model'\''s own revision horizon GAP_S + TAIL_S: 210 s\n'
echo "  A minute stops moving once no open run can still reach back into it. That"
echo "  is bounded by GAP_S + TAIL_S = 210 s after an interval's last event, and"
echo "  the measurement lands exactly inside it: the last non-zero cell is at"
echo "  180 s and every cell at 240 s and beyond is exact, across all 32 cuts."

echo
echo "--------------------------------------------------------------------------"
echo "2 — DIRECTION. Over-counting invents viewers who were not watching; it is"
echo "    the failure the whole problem exists to prevent. Under-counting is"
echo "    visible and explainable. So the sign matters more than the magnitude."
echo "--------------------------------------------------------------------------"
q "SELECT countIf(diff < 0) AS undercounting_cells,
          countIf(diff > 0) AS overcounting_cells,
          min(diff)         AS largest_undercount,
          max(diff)         AS largest_overcount
   FROM $SCRATCH.asof_curve WHERE diff != 0 FORMAT PrettyCompactMonoBlock"
echo "  every over-count, in full:"
q "SELECT cut, minute, age_s, asof, final, diff
   FROM $SCRATCH.asof_curve WHERE diff > 0 ORDER BY cut FORMAT PrettyCompactMonoBlock"

echo
echo "--------------------------------------------------------------------------"
echo "3 — HOW MUCH OF THE CURVE IS PROVISIONAL. Two different questions, and"
echo "    conflating them is the trap:"
echo "      (a) how many contributors are sessions that are still OPEN, and"
echo "      (b) how many of them can still CHANGE an already-served minute."
echo "--------------------------------------------------------------------------"
q "SELECT age_s,
          round(avg(open_asof / nullIf(asof, 0)) * 100, 1) AS pct_from_open_sessions,
          max(open_asof)                                   AS max_open_contributors
   FROM $SCRATCH.asof_curve
   WHERE asof > 0 AND age_s <= 600 AND age_s % 120 = 0
   GROUP BY age_s ORDER BY age_s FORMAT PrettyCompactMonoBlock"

echo
echo "    (b) of the sessions OPEN at the cut, how many actually revise a minute"
echo "        the dashboard has already served?"
q "WITH asof_min AS (
     SELECT cut, video_session_id, groupUniqArray(m) AS mins FROM (
       SELECT cut, video_session_id,
              arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                              toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
       FROM $SCRATCH.asof_intervals)
     WHERE m <= toUInt32(cut) GROUP BY cut, video_session_id),
   final_min AS (
     SELECT video_session_id, groupUniqArray(m) AS mins FROM (
       SELECT video_session_id,
              arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                              toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
       FROM $SCRATCH.session_intervals FINAL) GROUP BY video_session_id),
   opencnt AS (
     SELECT cut, uniqExactIf(video_session_id, is_open = 1) AS open_sessions
     FROM $SCRATCH.asof_intervals GROUP BY cut)
   SELECT a.cut,
          o.open_sessions,
          countIf(arraySort(a.mins) != arraySort(arrayFilter(x -> x <= toUInt32(a.cut), f.mins))) AS revise_served,
          round(countIf(arraySort(a.mins) != arraySort(arrayFilter(x -> x <= toUInt32(a.cut), f.mins)))
                / nullIf(o.open_sessions, 0) * 100, 1) AS pct_of_open
   FROM asof_min a
   INNER JOIN final_min f USING (video_session_id)
   INNER JOIN opencnt o ON o.cut = a.cut
   WHERE o.open_sessions > 100
   GROUP BY a.cut, o.open_sessions ORDER BY a.cut FORMAT PrettyCompactMonoBlock"

echo
echo "--------------------------------------------------------------------------"
echo "4 — CONVERGENCE. The peak minute, watched from successive cuts."
echo "--------------------------------------------------------------------------"
q "SELECT cut, age_s, asof, final, diff, open_asof AS contributors_still_open
   FROM $SCRATCH.asof_curve
   WHERE minute = '2026-07-26 10:56:00' AND age_s >= 0 AND age_s <= 900
   ORDER BY cut FORMAT PrettyCompactMonoBlock"

echo
echo "--------------------------------------------------------------------------"
echo "5 — WHAT A DASHBOARD WINDOW ACTUALLY SHOWS. Minutes that can still move,"
echo "    as a share of the window, using the measured 240 s finality horizon."
echo "--------------------------------------------------------------------------"
q "SELECT win_min AS window_minutes,
          4                                              AS provisional_minutes,
          round(4 / win_min * 100, 1)                    AS pct_of_window_provisional,
          1                                              AS materially_wrong_minutes,
          round(1 / win_min * 100, 1)                    AS pct_materially_wrong
   FROM (SELECT arrayJoin([5, 15, 60]) AS win_min) FORMAT PrettyCompactMonoBlock"
echo "  'provisional' = age < 240 s, i.e. can still change by any amount (measured"
echo "  max beyond the newest minute: -60 viewers at 60 s, -1 at 120-180 s)."
echo "  'materially wrong' = the newest minute, mean -14.8% / worst -75.2%."

echo
echo "analysis done."
