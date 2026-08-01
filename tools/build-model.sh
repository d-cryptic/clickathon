#!/usr/bin/env bash
# tools/build-model.sh — rebuild the whole model from ev_raw, in order.
#
#   ev_raw -> session_intervals (30_build_intervals.sql)
#          -> cc_user_minute    (45_user_concurrency.sql backfill — ADR 0016)
#          -> cc_minute_delta   (40_deltas.sql)
#          -> cc_hour_agg       (50_hour_agg.sql)
#
# Order matters and the steps are NOT individually idempotent in the same way:
#   session_intervals is a ReplacingMergeTree keyed (video_session_id,
#     interval_start), so a re-insert replaces.
#   cc_minute_delta is an AggregatingMergeTree of SUMS. A second insert without
#     a TRUNCATE silently DOUBLES every number. There is no dedup to save you,
#     and the result looks plausible — so this script truncates first, always.
#   cc_user_minute is, since ADR 0016, a ReplacingMergeTree(computed_at) of
#     uniqExact states, populated by the canonical backfill INSERT inside
#     sql/45_user_concurrency.sql — the MV that used to fire during the
#     intervals insert is retired, because a per-block MV writes PARTIAL states
#     and under replace semantics the newest write wins, so a partial state
#     would erase a complete bucket. Re-applying 45 replaces every bucket it
#     recomputes AND writes retraction tombstones for buckets that vanished, so
#     the truncate here is storage hygiene (drop tombstone keys), not the
#     correctness mechanism it used to be when the tier was a set union that
#     could only ever grow (measured then: served 2,953 vs true 2,844,
#     ADR 0012).
#   cc_hour_agg is a ReplacingMergeTree keyed (dims, hour). A re-run REPLACES a
#     matching key, so it cannot double — but it was not rebuilt here at all,
#     so `make model` left the hour/day views serving a pre-fix number while
#     the minute views served the new one (measured: 2,887 vs 2,917). It is
#     truncated rather than replaced-in-place, because replacement cannot
#     retract a (dims, hour) key the new derivation no longer produces.
#     (The incremental publisher handles that same case without a truncate by
#     writing all-zero rows that the views filter — ADR 0016.)
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

# ── The guard that was missing on 2026-08-01 ────────────────────────────────
# This script TRUNCATEs four tables and rebuilds them. Run against the GRADED
# database it destroys and recreates the answers we are scored on, and there is
# no undo. That is not hypothetical: a worktree on a stale base ran exactly this
# against `sonyliv`, with pre-ADR-0009 SQL, and left the service serving two
# different model generations — minute peak 2,887 with 1,949.331 hours, hour
# peak 2,917 — for about two hours until an external audit noticed. Nothing in
# this script objected, because until now nothing in it asked.
#
# So: rebuilding the graded database is allowed, but it must be DELIBERATE.
# Set REBUILD_GRADED=yes for that one invocation. Every other target — local,
# any scratch database — is unaffected and needs no ceremony.
GRADED_DB="${GRADED_DB:-sonyliv}"
if [ "$TARGET" = cloud ]; then
  TARGET_DB="${CH_DATABASE:-}"
  if [ "$TARGET_DB" = "$GRADED_DB" ] && [ "${REBUILD_GRADED:-}" != yes ]; then
    cat >&2 <<EOF
tools/build-model.sh: REFUSING to rebuild the graded database '$GRADED_DB'.

  This truncates session_intervals, cc_user_minute, cc_minute_delta and
  cc_hour_agg on the service we are scored on, then rebuilds them from ev_raw.
  If your working tree is on a stale base, the rebuild writes STALE SQL over
  correct answers and the result looks plausible. That has happened once.

  Before you override, confirm all three:
    1. git log --oneline -1        is a commit you meant to build from
    2. git status --porcelain      is clean
    3. you actually intend to replace the graded answers

  Then:  REBUILD_GRADED=yes TARGET=cloud tools/build-model.sh

  For any other purpose use a scratch database — sql/70_truncation_test.sql
  shows the pattern — or run without TARGET=cloud for local.
EOF
    exit 1
  fi
  if [ "$TARGET_DB" = "$GRADED_DB" ]; then
    echo "== ⚠ REBUILDING THE GRADED DATABASE '$GRADED_DB' (REBUILD_GRADED=yes)"
    echo "==   commit $(git rev-parse --short HEAD 2>/dev/null || echo '?')  tree $( [ -z "$(git status --porcelain 2>/dev/null)" ] && echo clean || echo DIRTY )"
  fi
fi

echo "== target: $TARGET"

echo "== 1/6  session_intervals (gap + pause, ADR 0001/0007)"
q "TRUNCATE TABLE session_intervals" >/dev/null
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/30_build_intervals.sql >/dev/null
q "SELECT concat('   intervals: ', toString(count()), ' over ', toString(uniqExact(video_session_id)), ' sessions') FROM session_intervals FINAL FORMAT TSVRaw"

echo "== 2/6  cc_user_minute (uniqExact per bucket, replaced not unioned — ADR 0016)"
# A pre-ADR-0016 database carries the AggregatingMergeTree shape, whose set
# union cannot retract a user. The engine cannot be ALTERed; the table is pure
# derived state, so the migration IS the rebuild: drop and let 45 recreate.
USER_ENGINE="$(q "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'cc_user_minute' FORMAT TSVRaw" | tr -d '[:space:]')"
case "$USER_ENGINE" in
  *ReplacingMergeTree* | "") : ;;   # current shape, or fresh — 45 creates it
  *)
    echo "   cc_user_minute is ${USER_ENGINE} (pre-ADR-0016) — dropping and recreating."
    echo "   Derived state only; sql/45_user_concurrency.sql rebuilds it below."
    q "DROP VIEW IF EXISTS mv_user_minute" >/dev/null
    q "DROP TABLE cc_user_minute" >/dev/null
    ;;
esac
# Truncate is storage hygiene here (drops retraction tombstones); the backfill
# inside 45 replaces every bucket regardless. See the header.
q "TRUNCATE TABLE IF EXISTS cc_user_minute" >/dev/null
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/45_user_concurrency.sql >/dev/null
q "SELECT concat('   user-minute buckets: ', toString(count())) FROM cc_user_minute FINAL FORMAT TSVRaw"

echo "== 3/6  cc_minute_delta (hour-clipped, ADR 0003)"
q "TRUNCATE TABLE cc_minute_delta" >/dev/null
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/40_deltas.sql >/dev/null
q "SELECT concat('   delta rows: ', toString(count()), '  opens ', toString(sum(starts)), '  closes ', toString(sum(ends))) FROM cc_minute_delta FORMAT TSVRaw"

echo "== 4/6  cc_hour_agg (the hour tier, ADR 0003)"
q "TRUNCATE TABLE IF EXISTS cc_hour_agg" >/dev/null   # IF EXISTS: 50_hour_agg.sql creates it just below
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/50_hour_agg.sql >/dev/null
q "SELECT concat('   hour rows: ', toString(count()), '  peak ', toString(max(peak))) FROM cc_hour_agg FINAL WHERE platform='*' AND country='*' AND content_id=-1 FORMAT TSVRaw"

echo "== 5/6  views"
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/20_views.sql >/dev/null
echo "   ok"

# Normalisation is READ-SIDE only (ADR 0011): UDFs plus views over cc_minute_delta.
# It stores nothing and rewrites no byte, so it cannot move the headline or the gate —
# but until it is applied, `hin` / `HIN` / `hin-hindi` / `hin-Hindi` stay four separate
# filter buckets and the drift audit does not exist. Everything in the file is
# CREATE OR REPLACE, so re-running is free. It comes last because its views read
# cc_minute_delta, which stage 2 builds.
echo "== 6/6  normalisation UDFs + views (ADR 0011)"
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/15_normalise.sql >/dev/null
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
