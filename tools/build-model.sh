#!/usr/bin/env bash
# tools/build-model.sh — rebuild the whole model from ev_raw, in order.
#
#   ev_raw -> session_intervals (30_build_intervals.sql)
#          -> cc_minute_delta   (40_deltas.sql)
#
# Order matters and the steps are NOT individually idempotent in the same way:
#   session_intervals is a ReplacingMergeTree keyed (video_session_id,
#     interval_start), so a re-insert replaces.
#   cc_minute_delta is an AggregatingMergeTree of SUMS. A second insert without
#     a TRUNCATE silently DOUBLES every number. There is no dedup to save you,
#     and the result looks plausible — so this script truncates first, always.
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

echo "== target: $TARGET"

echo "== 1/3  session_intervals (gap + pause, ADR 0001/0007)"
q "TRUNCATE TABLE session_intervals" >/dev/null
TARGET="$TARGET" tools/apply-sql.sh sql/30_build_intervals.sql >/dev/null
q "SELECT concat('   intervals: ', toString(count()), ' over ', toString(uniqExact(video_session_id)), ' sessions') FROM session_intervals FINAL FORMAT TSVRaw"

echo "== 2/3  cc_minute_delta (hour-clipped, ADR 0003)"
q "TRUNCATE TABLE cc_minute_delta" >/dev/null
TARGET="$TARGET" tools/apply-sql.sh sql/40_deltas.sql >/dev/null
q "SELECT concat('   delta rows: ', toString(count()), '  opens ', toString(sum(starts)), '  closes ', toString(sum(ends))) FROM cc_minute_delta FORMAT TSVRaw"

echo "== 3/3  views"
TARGET="$TARGET" tools/apply-sql.sh sql/20_views.sql >/dev/null
echo "   ok"

echo "== reconcile: delta serving layer vs interval expansion, every minute"
q "
WITH dense AS (
  SELECT minute, concurrent FROM v_concurrency_minute_delta_total
  ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
SELECT if(countIf(dense.concurrent != i.concurrent) = 0,
          concat('   PASS  ', toString(count()), ' minutes, peak ', toString(max(i.concurrent))),
          concat('   FAIL  ', toString(countIf(dense.concurrent != i.concurrent)), ' of ',
                 toString(count()), ' minutes disagree'))
FROM dense INNER JOIN v_concurrency_minute_intervals i USING (minute) FORMAT TSVRaw"
