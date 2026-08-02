#!/usr/bin/env bash
# evidence/query-modes/capture.sh — measure every query-mode shape (queries/*.sql)
# against a SINGLE-GENERATION scratch build of the model, READ-ONLY, and record
# latency + bytes read the same way tools/bench.sh does for the benchmark set.
#
# Same methodology as evidence/query-performance.md: per query, 1 EXPLAIN
# indexes=1 pass, then 3 timed runs with query caches OFF (use_query_cache=0,
# use_query_condition_cache=0), reading rows/bytes from X-ClickHouse-Summary.
# Every run carries log_comment='qmode:<query>:run<N>:<tag>' and its query id is
# recorded in results/runs.tsv, so each number is auditable in system.query_log.
#
# WHY A SCRATCH DATABASE (QM_DATABASE, default sonyliv_u3), NOT THE GRADED ONE:
# the graded db currently serves MIXED tier generations (hour tier 16:39, delta
# tier 19:18 — evidence/query-robustness/README.md F1), so a point query and an
# interval query would disagree there for reasons that have nothing to do with
# query modes. The scratch db is built from the graded ev_raw at dev HEAD and is
# gate-green (see results/meta.env), so cross-tier agreement is meaningful.
#
# This script only ever sends SELECT / EXPLAIN. It never writes anywhere.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && . ./.env && set +a

QM_DIR=evidence/query-modes
QDIR="$QM_DIR/queries"
RESULTS="$QM_DIR/results"
QM_TAG="${QM_TAG:-qmode-$(date -u +%Y%m%dT%H%M%SZ)}"
QM_DATABASE="${QM_DATABASE:-sonyliv_u3}"
RUNS_PER_QUERY=3

H="${CH_HOST:?CH_HOST unset — fill in .env}"
H="${H#https://}"; H="${H#http://}"; H="${H%/}"
URL="https://${H}:${CH_PORT}/?database=${QM_DATABASE}"

mkdir -p "$RESULTS"
: > "$RESULTS/runs.tsv"

# ch_query <sql> <outfile> <format> [extra --url-query args...]
# Prints "<wall_seconds>\t<query_id>\t<summary_json>" on stdout.
ch_query() {
  local sql="$1" out="$2" fmt="$3"; shift 3
  local hdr wall qid summary
  hdr=$(mktemp)
  wall=$(curl -sS --fail-with-body -D "$hdr" -o "$out" -w '%{time_total}' \
    --user "${CH_USER}:${CH_PASSWORD}" \
    --url-query "wait_end_of_query=1" \
    --url-query "default_format=${fmt}" \
    "$@" "$URL" --data-binary "$sql")
  qid=$(grep -i '^x-clickhouse-query-id' "$hdr" | tail -1 | tr -d '\r' | cut -d' ' -f2)
  summary=$(grep -i '^x-clickhouse-summary' "$hdr" | tail -1 | tr -d '\r' | cut -d' ' -f2-)
  rm -f "$hdr"
  printf '%s\t%s\t%s\n' "$wall" "$qid" "$summary"
}

# Build --url-query param_* args from a .params sidecar (key=value per line).
param_args() {
  local pfile="$1"; PARAM_ARGS=()
  [ -f "$pfile" ] || return 0
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    PARAM_ARGS+=(--url-query "param_${k}=${v}")
  done < "$pfile"
}

echo "== warm-up (service auto-suspends; discard the first responses) =="
t0=$(mktemp)
ch_query "SELECT 1" "$t0" TSVRaw >/dev/null
param_args "$QDIR/pm01_minute_total_range.params"
ch_query "$(cat "$QDIR/pm01_minute_total_range.sql")" "$t0" TSVRaw "${PARAM_ARGS[@]}" >/dev/null
rm -f "$t0"
echo "   warm."

for qfile in "$QDIR"/*.sql; do
  qid_name=$(basename "$qfile" .sql)
  sql=$(cat "$qfile")
  param_args "${qfile%.sql}.params"

  echo "== $qid_name =="

  # granule pruning, once per query
  ch_query "EXPLAIN indexes = 1 ${sql}" "$RESULTS/${qid_name}.explain.txt" TSVRaw \
    "${PARAM_ARGS[@]}" \
    --url-query "log_comment=qmode-explain:${qid_name}:${QM_TAG}" >/dev/null

  # timed runs, caches off
  for run in $(seq 1 "$RUNS_PER_QUERY"); do
    body="$RESULTS/${qid_name}.run${run}.body"
    line=$(ch_query "$sql" "$body" PrettyCompactMonoBlock \
      "${PARAM_ARGS[@]}" \
      --url-query "use_query_cache=0" \
      --url-query "use_query_condition_cache=0" \
      --url-query "log_comment=qmode:${qid_name}:run${run}:${QM_TAG}")
    sha=$(shasum -a 256 "$body" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\n' "$qid_name" "$run" "$sha" "$line" >> "$RESULTS/runs.tsv"
    echo "   run${run}: $(echo "$line" | cut -f2)"
  done

  # run 1 is the committed answer; all runs must agree (caches off, data static)
  mv "$RESULTS/${qid_name}.run1.body" "$RESULTS/${qid_name}.answer.txt"
  rm -f "$RESULTS/${qid_name}".run*.body
done

# metadata for the report
META="$RESULTS/meta.env"
{
  echo "QM_TAG=${QM_TAG}"
  echo "COMMIT=$(git rev-parse --short HEAD)"
  echo "TARGET=cloud database=${QM_DATABASE} (scratch, single generation, dev HEAD)"
} > "$META"
v=$(mktemp); ch_query "SELECT version()" "$v" TSVRaw >/dev/null
printf 'SERVER_VERSION=%s\n' "$(cat "$v")" >> "$META"; rm -f "$v"
c=$(mktemp)
ch_query "SELECT concat('ev_raw=', toString((SELECT count() FROM ev_raw)), ' session_intervals=', toString((SELECT count() FROM session_intervals)), ' cc_minute_delta=', toString((SELECT count() FROM cc_minute_delta)), ' cc_hour_agg=', toString((SELECT count() FROM cc_hour_agg)))" "$c" TSVRaw >/dev/null
printf 'ROW_COUNTS=%s\n' "$(cat "$c")" >> "$META"; rm -f "$c"
g=$(mktemp)
ch_query "
WITH dense AS (
  SELECT minute, concurrent FROM v_concurrency_minute_delta_total
  ORDER BY minute WITH FILL STEP toIntervalSecond(60) INTERPOLATE (concurrent AS concurrent)
)
SELECT if(countIf(dense.concurrent != i.concurrent) = 0,
          concat('PASS ', toString(count()), ' minutes, peak ', toString(max(i.concurrent))),
          'FAIL')
FROM dense INNER JOIN v_concurrency_minute_intervals i USING (minute)" "$g" TSVRaw >/dev/null
printf 'RECONCILE_GATE=%s\n' "$(cat "$g")" >> "$META"; rm -f "$g"

echo "== DONE — results under $RESULTS (tag ${QM_TAG}) =="
