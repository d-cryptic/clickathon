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

# ── The guard that was missing on 2026-08-01 ────────────────────────────────
# This script TRUNCATEs tables and rebuilds them. Run against the GRADED
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
#
# NOT overridable. Cross-model validation (Codex, check 5, 2026-08-02) found that
# `GRADED_DB="${GRADED_DB:-sonyliv}"` let any caller disable this guard with
# GRADED_DB=anything — `CH_DATABASE=sonyliv GRADED_DB=scratch` no longer matches,
# so the script walks straight past this block into its two unqualified
# TRUNCATEs. A guard whose SUBJECT is caller-controlled is not a guard: the whole
# point is to protect one fixed database whose identity is not a runtime opinion.
# `readonly` makes a later assignment fail loudly instead of silently widening
# the hole.
readonly GRADED_DB=sonyliv
if [ "$TARGET" = cloud ]; then
  TARGET_DB="${CH_DATABASE:-}"
  if [ "$TARGET_DB" = "$GRADED_DB" ] && [ "${REBUILD_GRADED:-}" != yes ]; then
    cat >&2 <<EOF
tools/build-model.sh: REFUSING to rebuild the graded database '$GRADED_DB'.

  This truncates session_intervals and cc_minute_delta on the service we are
  scored on, then rebuilds them from ev_raw. If your working tree is on a
  stale base, the rebuild writes STALE SQL over correct answers and the
  result looks plausible. That has happened once.

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

echo "== 1/3  session_intervals (gap + pause, ADR 0001/0007)"
q "TRUNCATE TABLE session_intervals" >/dev/null
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/30_build_intervals.sql >/dev/null
q "SELECT concat('   intervals: ', toString(count()), ' over ', toString(uniqExact(video_session_id)), ' sessions') FROM session_intervals FINAL FORMAT TSVRaw"

echo "== 2/3  cc_minute_delta (hour-clipped, ADR 0003)"
q "TRUNCATE TABLE cc_minute_delta" >/dev/null
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/40_deltas.sql >/dev/null
q "SELECT concat('   delta rows: ', toString(count()), '  opens ', toString(sum(starts)), '  closes ', toString(sum(ends))) FROM cc_minute_delta FORMAT TSVRaw"

echo "== 3/3  views"
TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/20_views.sql >/dev/null
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
