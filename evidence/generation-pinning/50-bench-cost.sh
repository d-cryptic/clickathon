#!/usr/bin/env bash
# 50-bench-cost.sh — what does pinning COST a reader?
#
# The 13 benchmark shapes (evidence/benchmark/*.sql), UNMODIFIED, run against
# the same data three ways on the same server:
#
#   ctl   gp_ctl — today's design: four plain tier tables, one model
#   ptr   gp_pin — ADR 0034 as specified: pinned base views whose predicate is
#                  `generation = (SELECT generation FROM v_active_generation)`,
#                  over tables holding THREE generations (1 committed + the two
#                  corrupt ones 40-killed-build.sh left behind — the pessimistic
#                  case, 2.9x the rows of gp_ctl)
#   lit   gp_pin — the same database with the four pinned views re-created with
#                  the generation as a LITERAL. Isolates the cost of the pointer
#                  indirection itself from the cost of pinning at all.
#
# Method, matching tools/bench.sh: caches off (use_query_cache=0,
# use_query_condition_cache=0), one discarded warm-up, then 3 timed runs, median
# of the server-side elapsed_ns from X-ClickHouse-Summary, with read_rows /
# read_bytes from the same header.
#
# Run 00-setup.sh and 40-killed-build.sh first. This script REPAIRS gp_ctl at the
# start — 40-killed-build.sh deliberately leaves it doubled, and a baseline that
# holds 2x the rows is not a baseline.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] && set -a && . ./.env && set +a

OUT=evidence/generation-pinning/50-bench-cost.tsv
BENCH_DIR=evidence/benchmark
RUNS=3
URLBASE="${CH_LOCAL_URL:?}/?user=${CH_LOCAL_USER:-app}&password=${CH_PASSWORD_LOCAL:?}"
ch() { env -u CH_DATABASE CH_DATABASE_LOCAL="$1" tools/ch "$2"; }

echo "== repairing gp_ctl (40-killed-build.sh left it doubled on purpose)"
env -u CH_DATABASE TARGET=local CH_DATABASE_LOCAL=gp_ctl tools/build-model.sh 2>&1 | grep -E "PASS|FAIL|delta rows" | sed 's/^/   /'

# LOCAL-ENVIRONMENT FIX, not a design change. sql/80_content.sql declares
# SOURCE(CLICKHOUSE(TABLE 'content_dim')) with no credentials, which connects as
# `default` with an empty password. That is right on Cloud and right in the
# local `default` database; in a scratch database on this container it fails
# AUTHENTICATION_FAILED and b13 cannot run at all. Both databases get the
# identical redefinition, so the comparison is unaffected — only b13's dictGet
# decoration depends on it, never the serving path being measured.
for db in gp_ctl gp_pin; do
  ch "$db" "CREATE OR REPLACE DICTIONARY dict_content (
              content_id Int64, title String, video_type String, category String)
            PRIMARY KEY content_id
            SOURCE(CLICKHOUSE(TABLE 'content_dim' DB '$db'
                              USER '${CH_LOCAL_USER:-app}' PASSWORD '${CH_PASSWORD_LOCAL}'))
            LIFETIME(MIN 300 MAX 600) LAYOUT(COMPLEX_KEY_HASHED())" >/dev/null
done

# run <db> <sql> <params-file> -> "elapsed_ns\tread_rows\tread_bytes"
run() {
  local db="$1" sql="$2" pfile="$3"
  local args=() hdr summary
  args=(--url-query "database=${db}" --url-query "default_format=TSVRaw"
        --url-query "wait_end_of_query=1"
        --url-query "use_query_cache=0" --url-query "use_query_condition_cache=0")
  if [ -f "$pfile" ]; then
    while IFS='=' read -r k v; do
      [ -n "$k" ] || continue
      args+=(--url-query "param_${k}=${v}")
    done < "$pfile"
  fi
  hdr=$(mktemp)
  curl -sS --fail-with-body -D "$hdr" -o /dev/null "${args[@]}" "$URLBASE" --data-binary "$sql" >/dev/null
  summary=$(grep -i '^x-clickhouse-summary' "$hdr" | tail -1 | tr -d '\r' | cut -d' ' -f2-)
  rm -f "$hdr"
  python3 -c "
import json
s=json.loads('''$summary''')
print('%s\t%s\t%s' % (s.get('elapsed_ns',0), s.get('read_rows',0), s.get('read_bytes',0)))"
}

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# repoint <mode> — swap gp_pin's four canonical views between pointer and literal
repoint() {
  local pin
  if [ "$1" = ptr ]; then pin="(SELECT generation FROM v_active_generation)"
  else                    pin="$(ch gp_pin "SELECT generation FROM v_active_generation FORMAT TSVRaw" | tr -d '[:space:]')"
  fi
  for pair in "session_intervals|gen_session_intervals| FINAL" "cc_minute_delta|gen_cc_minute_delta|" \
              "cc_hour_agg|gen_cc_hour_agg| FINAL" "cc_user_minute|gen_cc_user_minute| FINAL"; do
    local name="${pair%%|*}" rest="${pair#*|}"
    ch gp_pin "CREATE OR REPLACE VIEW ${name} AS SELECT * EXCEPT generation
               FROM ${rest%%|*}${rest#*|} WHERE generation = ${pin}" >/dev/null
  done
}

echo
echo "== rows held per tier (gp_pin deliberately holds 3 generations)"
for db in gp_ctl gp_pin; do
  ch "$db" "SELECT '$db', table, sum(rows), formatReadableSize(sum(bytes_on_disk))
            FROM system.parts WHERE database = '$db' AND active
              AND table IN ('cc_minute_delta','cc_hour_agg','cc_user_minute','session_intervals',
                            'gen_cc_minute_delta','gen_cc_hour_agg','gen_cc_user_minute','gen_session_intervals')
            GROUP BY table ORDER BY table FORMAT TSV" | sed 's/^/   /'
done

printf 'query\tmode\telapsed_ms\tread_rows\tread_bytes\n' > "$OUT"
echo
printf '%-38s %8s %8s %8s   %10s %10s %10s\n' query ctl_ms ptr_ms lit_ms ctl_rows ptr_rows lit_rows
printf '%.0s-' {1..100}; echo

for qfile in "$BENCH_DIR"/b*.sql; do
  name=$(basename "$qfile" .sql)
  sql=$(cat "$qfile")
  pfile="${qfile%.sql}.params"
  declare -A MS RR
  for mode in ctl ptr lit; do
    case $mode in
      ctl) db=gp_ctl ;;
      ptr) db=gp_pin; repoint ptr ;;
      lit) db=gp_pin; repoint lit ;;
    esac
    run "$db" "$sql" "$pfile" >/dev/null   # warm, discarded
    ns=(); rr=(); rb=()
    for _ in $(seq 1 $RUNS); do
      IFS=$'\t' read -r a b c < <(run "$db" "$sql" "$pfile")
      ns+=("$a"); rr+=("$b"); rb+=("$c")
    done
    MS[$mode]=$(python3 -c "print(round($(median "${ns[@]}")/1e6, 2))")
    RR[$mode]=$(median "${rr[@]}")
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$mode" "${MS[$mode]}" "${RR[$mode]}" "$(median "${rb[@]}")" >> "$OUT"
  done
  printf '%-38s %8s %8s %8s   %10s %10s %10s\n' "$name" \
    "${MS[ctl]}" "${MS[ptr]}" "${MS[lit]}" "${RR[ctl]}" "${RR[ptr]}" "${RR[lit]}"
done
repoint ptr   # leave gp_pin in its specified shape

echo
echo "== totals"
python3 - "$OUT" <<'PY'
import sys, collections
rows = [l.split('\t') for l in open(sys.argv[1]).read().splitlines()[1:]]
agg = collections.defaultdict(lambda: [0.0, 0, 0])
for q, m, ms, rr, rb in rows:
    a = agg[m]; a[0] += float(ms); a[1] += int(rr); a[2] += int(rb)
c = agg['ctl']
for m, label in (('ctl', 'today'), ('ptr', 'pinned, control-table pointer'), ('lit', 'pinned, literal')):
    a = agg[m]
    if m == 'ctl':
        print("   %-30s %8.2f ms  %9d rows  %11d bytes" % (label, *a))
    else:
        print("   %-30s %8.2f ms  %9d rows  %11d bytes   (%+.1f%% time, %+.1f%% rows, %+.1f%% bytes)"
              % (label, a[0], a[1], a[2],
                 100*(a[0]-c[0])/c[0], 100*(a[1]-c[1])/c[1], 100*(a[2]-c[2])/c[2]))
print()
print("   per-query mean overhead:  pointer %+.2f ms   literal %+.2f ms   (over %d queries)"
      % ((agg['ptr'][0]-c[0])/13, (agg['lit'][0]-c[0])/13, 13))
PY
echo
echo "   full table: $OUT"
