#!/usr/bin/env bash
# 40-killed-build.sh — THE PROOF. Kill a build after the delta insert, both ways.
#
# The incident, 2026-08-02: a rebuild of the graded database died at stage 4/6 on
# a missing `cube_level` column, AFTER the delta insert had run twice.
# cc_minute_delta was left holding 56,146 rows instead of 28,073 and the serving
# layer answered a peak of 5,834 instead of 2,917. The build's own reconcile —
# which catches doubling instantly — sits at the END of the script and was never
# reached. An external audit found it hours later.
#
# Case A reproduces exactly that on gp_ctl, today's design.
# Case B does the same thing to gp_pin, the generation-pinned design of ADR 0034,
#        twice: killed before the gates, and run to completion so the gates fire.
#
# Nothing here touches the graded database. Run 00-setup.sh first.
set -euo pipefail
cd "$(dirname "$0")/../.."

CTL=gp_ctl
PIN=gp_pin
ch() { env -u CH_DATABASE CH_DATABASE_LOCAL="$1" tools/ch "$2"; }
apply() { env -u CH_DATABASE TARGET=local CH_DATABASE_LOCAL="$1" tools/apply-sql.sh --database "$1" "${@:2}" >/dev/null; }

served() {  # served <db> — what a dashboard reads, right now
  printf '   %-8s served peak %-6s  delta rows %-6s  hour-tier peak %-6s  intervals %s\n' "$1" \
    "$(ch "$1" "SELECT max(concurrent) FROM v_concurrency_minute_delta_total FORMAT TSVRaw")" \
    "$(ch "$1" "SELECT count() FROM cc_minute_delta FORMAT TSVRaw")" \
    "$(ch "$1" "SELECT max(peak) FROM v_concurrency_hour_total FORMAT TSVRaw")" \
    "$(ch "$1" "SELECT count() FROM session_intervals FORMAT TSVRaw")"
}

echo "=================================================================="
echo "BEFORE — both databases hold the same, correct model"
echo "=================================================================="
served "$CTL"
served "$PIN"

echo
echo "=================================================================="
echo "CASE A — today's design (gp_ctl). Build dies at stage 4/6."
echo "=================================================================="
echo "   stage 3/6: TRUNCATE cc_minute_delta, then the delta insert runs TWICE"
ch "$CTL" "TRUNCATE TABLE cc_minute_delta" >/dev/null
apply "$CTL" sql/40_deltas.sql
apply "$CTL" sql/40_deltas.sql
echo "   stage 4/6: DIES (in the real incident: No such column cube_level)"
echo "   stages 5, 6 and all three reconcile gates: NEVER RUN"
echo
echo "   what a dashboard reads one second later:"
served "$CTL"
CTL_PEAK="$(ch "$CTL" "SELECT max(concurrent) FROM v_concurrency_minute_delta_total FORMAT TSVRaw")"
CTL_ROWS="$(ch "$CTL" "SELECT count() FROM cc_minute_delta FORMAT TSVRaw")"
echo
echo "   >>> SERVED, SILENTLY WRONG: peak $CTL_PEAK (true 2917), $CTL_ROWS rows (true 28073)."
echo "   >>> The hour tier still says 2917, so the two tiers now disagree — which"
echo "   >>> is the only visible symptom, and nothing was watching for it."

echo
echo "=================================================================="
echo "CASE B1 — ADR 0034 (gp_pin). Same corruption, build killed after staging."
echo "=================================================================="
set +e
DOUBLE_DELTA=yes KILL_AFTER=stage TARGET=local tools/build-generation.sh --database "$PIN" 2>&1 \
  | sed 's/^/   | /'
RC=${PIPESTATUS[0]}
set -e
echo "   build exit code: $RC (killed, exactly as the real one was)"
echo
echo "   generations on disk:"
ch "$PIN" "SELECT generation, status, is_active FROM v_generation_status FORMAT TSV" | sed 's/^/     /'
echo "   rows staged for the killed generation (they ARE there — just unreachable):"
ch "$PIN" "SELECT generation, count() FROM gen_cc_minute_delta GROUP BY generation ORDER BY generation FORMAT TSV" | sed 's/^/     /'
echo
echo "   what a dashboard reads one second later:"
served "$PIN"

echo
echo "=================================================================="
echo "CASE B2 — ADR 0034. Same corruption, build allowed to RUN TO THE END."
echo "=================================================================="
echo "   (the failure mode where nothing crashes and the model is simply wrong)"
set +e
DOUBLE_DELTA=yes TARGET=local tools/build-generation.sh --database "$PIN" 2>&1 | sed 's/^/   | /'
RC=${PIPESTATUS[0]}
set -e
echo "   build exit code: $RC"
echo
echo "   generations on disk:"
ch "$PIN" "SELECT generation, status, is_active FROM v_generation_status FORMAT TSV" | sed 's/^/     /'
echo
echo "   what a dashboard reads one second later:"
served "$PIN"

PIN_PEAK="$(ch "$PIN" "SELECT max(concurrent) FROM v_concurrency_minute_delta_total FORMAT TSVRaw")"
PIN_ROWS="$(ch "$PIN" "SELECT count() FROM cc_minute_delta FORMAT TSVRaw")"

echo
echo "=================================================================="
echo "VERDICT"
echo "=================================================================="
printf '   today  (gp_ctl): served peak %s, %s delta rows   <- the incident\n' "$CTL_PEAK" "$CTL_ROWS"
printf '   ADR 0034 (gp_pin): served peak %s, %s delta rows   <- unchanged, twice over\n' "$PIN_PEAK" "$PIN_ROWS"
echo
echo "   The corrupt generations are still on disk and still readable if you ask"
echo "   for one by name — which is the point: they are INSPECTABLE and they are"
echo "   NOT SERVED. Retire one with a metadata-only DROP PARTITION:"
ch "$PIN" "SELECT concat('     ALTER TABLE gen_cc_minute_delta DROP PARTITION ', partition)
           FROM system.parts WHERE database = '$PIN' AND table = 'gen_cc_minute_delta' AND active
             AND toUInt32(splitByChar(',', trim(BOTH '()' FROM partition))[1]) != (SELECT generation FROM v_active_generation)
           GROUP BY partition ORDER BY partition LIMIT 3 FORMAT TSVRaw"
