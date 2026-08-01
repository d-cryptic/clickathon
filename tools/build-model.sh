#!/usr/bin/env bash
# tools/build-model.sh — rebuild the whole model from ev_raw, in order.
#
#   ev_raw -> session_intervals (30_build_intervals.sql)
#          -> cc_minute_delta   (40_deltas.sql)
#          -> cc_user_minute    (mv_user_minute, fires on the intervals INSERT)
#          -> cc_hour_agg       (50_hour_agg.sql)
#
# Order matters and the steps are NOT individually idempotent in the same way:
#   session_intervals is a ReplacingMergeTree keyed (video_session_id,
#     interval_start), so a re-insert replaces.
#   cc_minute_delta is an AggregatingMergeTree of SUMS. A second insert without
#     a TRUNCATE silently DOUBLES every number. There is no dedup to save you,
#     and the result looks plausible — so this script truncates first, always.
#   cc_user_minute is an AggregatingMergeTree of uniqExact SETS, fed by the MV
#     mv_user_minute. A set union does NOT double on replay, which is exactly
#     why this table went unnoticed: rebuilding identical intervals is a no-op
#     on the number while tripling the storage. It breaks the moment a rebuild
#     produces DIFFERENT intervals — the old and the new attribution then both
#     survive, and a set union can only ADD users, never retract one. Measured
#     (ADR 0012): user peak served 2,953 against a true 2,844. So it is
#     truncated too — and BEFORE the intervals insert, because the MV writes
#     during that insert and a truncate afterwards would delete the rebuild.
#   cc_hour_agg is a ReplacingMergeTree keyed (dims, hour). A re-run REPLACES a
#     matching key, so it cannot double — but it was not rebuilt here at all,
#     so `make model` left the hour/day views serving a pre-fix number while
#     the minute views served the new one (measured: 2,887 vs 2,917). It is
#     truncated rather than replaced-in-place, because replacement cannot
#     retract a (dims, hour) key the new derivation no longer produces.
#
#   tools/build-model.sh              # local
#   TARGET=cloud tools/build-model.sh # the graded service
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a
TARGET="${TARGET:-local}"

q() {  # q <sql>
  if [ "$TARGET" = cloud ]; then tools/ch -c "$1"; else tools/ch "$1"; fi
}

# gate <sql> — run a check that prints its own PASS/FAIL line, and REMEMBER a
# failure so the script exits non-zero at the end. These used to print FAIL and
# exit 0, which meant `make model && <anything>` ran the <anything> on a broken
# model. All three tier checks below are gates; the run continues past a failure
# so you see every tier's verdict in one go, not just the first that broke.
GATE_FAILED=0
gate() {
  local out
  out="$(q "$1")"
  printf '%s\n' "$out"
  case "$out" in *FAIL*) GATE_FAILED=1 ;; esac
}

echo "== target: $TARGET"

echo "== 1/4  session_intervals + cc_user_minute (gap + pause, ADR 0001/0007)"
# mv_user_minute is what repopulates cc_user_minute, and it only fires on an
# INSERT into session_intervals. Truncating the table without the MV in place
# would leave the user tier serving zeros — silently, since every view still
# resolves. Refuse instead.
if [ "$(q "SELECT count() FROM system.tables WHERE database = currentDatabase() AND name = 'mv_user_minute'" | tr -d '[:space:]')" != "1" ]; then
  echo "!! mv_user_minute is missing — apply sql/45_user_concurrency.sql first," >&2
  echo "!! or cc_user_minute will be truncated with nothing to refill it." >&2
  exit 1
fi
q "TRUNCATE TABLE session_intervals" >/dev/null
q "TRUNCATE TABLE IF EXISTS cc_user_minute" >/dev/null   # BEFORE the insert — see header
TARGET="$TARGET" tools/apply-sql.sh sql/30_build_intervals.sql >/dev/null
q "SELECT concat('   intervals: ', toString(count()), ' over ', toString(uniqExact(video_session_id)), ' sessions') FROM session_intervals FINAL FORMAT TSVRaw"
q "SELECT concat('   user-minute rows: ', toString(count())) FROM cc_user_minute FORMAT TSVRaw"

echo "== 2/4  cc_minute_delta (hour-clipped, ADR 0003)"
q "TRUNCATE TABLE cc_minute_delta" >/dev/null
TARGET="$TARGET" tools/apply-sql.sh sql/40_deltas.sql >/dev/null
q "SELECT concat('   delta rows: ', toString(count()), '  opens ', toString(sum(starts)), '  closes ', toString(sum(ends))) FROM cc_minute_delta FORMAT TSVRaw"

echo "== 3/4  cc_hour_agg (the hour tier, ADR 0003)"
q "TRUNCATE TABLE IF EXISTS cc_hour_agg" >/dev/null   # IF EXISTS: 50_hour_agg.sql creates it just below
TARGET="$TARGET" tools/apply-sql.sh sql/50_hour_agg.sql >/dev/null
q "SELECT concat('   hour rows: ', toString(count()), '  peak ', toString(max(peak))) FROM cc_hour_agg FINAL WHERE platform='*' AND country='*' AND content_id=-1 FORMAT TSVRaw"

echo "== 4/4  views"
TARGET="$TARGET" tools/apply-sql.sh sql/20_views.sql >/dev/null
echo "   ok"

echo "== reconcile: delta serving layer vs interval expansion, every minute"
gate "
WITH dense AS (
  SELECT minute, concurrent FROM v_concurrency_minute_delta_total
  ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
SELECT if(countIf(dense.concurrent != i.concurrent) = 0,
          concat('   PASS  ', toString(count()), ' minutes, peak ', toString(max(i.concurrent))),
          concat('   FAIL  ', toString(countIf(dense.concurrent != i.concurrent)), ' of ',
                 toString(count()), ' minutes disagree'))
FROM dense INNER JOIN v_concurrency_minute_intervals i USING (minute) FORMAT TSVRaw"

# ---------------------------------------------------------------------------
# USER TIER GATE. The check that would have caught ADR 0012's defect the day it
# appeared. cc_user_minute is a set union, so a contaminated table stays
# PLAUSIBLE — it drifts upward and never down. Comparing the served number to
# session_intervals expanded directly is the only thing that sees it.
#
# FULL OUTER JOIN, not INNER: contamination also leaves behind whole MINUTES
# that the current derivation no longer produces (measured: 3,743 served vs
# 3,732 real), and an inner join would quietly skip exactly those.
# ---------------------------------------------------------------------------
echo "== reconcile: user tier vs interval expansion, every minute"
gate "
WITH truth AS (
  SELECT toDateTime(m) AS minute, uniqExact(user_id) AS u
  FROM (
    SELECT user_id, arrayJoin(range(toUInt32(toStartOfMinute(interval_start)),
                                    toUInt32(toStartOfMinute(interval_end)) + 1, 60)) AS m
    FROM session_intervals FINAL
  ) GROUP BY minute
),
served AS (SELECT minute, concurrent_users AS u FROM v_user_concurrency_minute_total)
SELECT if(countIf(served.u != truth.u) = 0,
          concat('   PASS  ', toString(count()), ' minutes, user peak ', toString(max(truth.u))),
          concat('   FAIL  ', toString(countIf(served.u != truth.u)), ' of ', toString(count()),
                 ' minutes disagree, served peak ', toString(max(served.u)),
                 ' vs true ', toString(max(truth.u))))
FROM served FULL OUTER JOIN truth USING (minute) FORMAT TSVRaw"

# ---------------------------------------------------------------------------
# HOUR TIER GATE. cc_hour_agg cannot double (ReplacingMergeTree), but it CAN go
# stale — it was not rebuilt by this script at all until ADR 0012, so the hour
# and day views served 2,887 while the minute views served 2,917. A tier that
# disagrees with the tier it is derived from is the whole failure mode.
# ---------------------------------------------------------------------------
echo "== reconcile: hour tier peak vs minute tier peak"
gate "
SELECT if(h = m, concat('   PASS  hour tier peak ', toString(h), ' = minute tier peak'),
                 concat('   FAIL  hour tier peak ', toString(h), ' != minute tier peak ', toString(m)))
FROM (
  SELECT (SELECT max(peak) FROM v_concurrency_hour_total)              AS h,
         (SELECT max(concurrent) FROM v_concurrency_minute_delta_total) AS m
) FORMAT TSVRaw"

if [ "$GATE_FAILED" != 0 ]; then
  echo "== BUILD FAILED — a tier disagrees with session_intervals. Do NOT benchmark this build." >&2
  exit 1
fi
