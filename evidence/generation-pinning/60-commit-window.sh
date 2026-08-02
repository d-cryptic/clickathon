#!/usr/bin/env bash
# 60-commit-window.sh — how long is the commit, and how long can tiers disagree?
#
# ADR 0034 offers two ways to move the pointer, and the difference between them
# is entirely a commit-atomicity question:
#
#   A  control-table pointer — ONE insert of one row. All four pinned views read
#      it, so all four tiers flip at the same instant. There is no window.
#   B  baked literal — four CREATE OR REPLACE VIEW statements. Each is atomic on
#      its own; four of them are four commit points, so a reader landing between
#      the first and the last sees a MIXTURE of two generations.
#
# B is measurably cheaper to read (see 50-bench-cost.sh: +1.43 ms/query vs
# +5.76 ms/query). This measures what that buys and what it costs.
#
# For scale: ADR 0023 measured today's cross-tier disagreement window, with no
# pinning at all, at 3.8 s (hour tier) to 7.3 s (user tier).
set -euo pipefail
cd "$(dirname "$0")/../.."
PIN=gp_pin
ch() { env -u CH_DATABASE CH_DATABASE_LOCAL="$PIN" tools/ch "$1"; }
N=10

G="$(ch "SELECT generation FROM v_active_generation FORMAT TSVRaw" | tr -d '[:space:]')"
echo "active generation: $G"
echo

echo "A · control-table commit — one INSERT, all four tiers"
for i in $(seq 1 $N); do
  python3 - <<PY
import subprocess, time, os
t = time.time()
subprocess.run(["tools/ch", "INSERT INTO model_generation (generation, status, notes) VALUES ($G, 'committed', 'commit-window probe')"],
               check=True, capture_output=True,
               env={**{k: v for k, v in os.environ.items() if k != 'CH_DATABASE'}, 'CH_DATABASE_LOCAL': '$PIN'})
print("%.1f" % ((time.time() - t) * 1000))
PY
done | sort -n | awk '{a[NR]=$1} END {printf "   n=%d  min %s ms  median %s ms  max %s ms\n", NR, a[1], a[int((NR+1)/2)], a[NR]}'
echo "   window during which tiers disagree: NONE — the four views resolve the"
echo "   same row, so there is no state in which some have flipped and some have not."
echo

echo "B · baked-literal commit — four CREATE OR REPLACE VIEW"
for i in $(seq 1 $N); do
  python3 - <<PY
import subprocess, time, os
env = {**{k: v for k, v in os.environ.items() if k != 'CH_DATABASE'}, 'CH_DATABASE_LOCAL': '$PIN'}
views = [("session_intervals", "gen_session_intervals", " FINAL"),
         ("cc_minute_delta",   "gen_cc_minute_delta",   ""),
         ("cc_hour_agg",       "gen_cc_hour_agg",       " FINAL"),
         ("cc_user_minute",    "gen_cc_user_minute",    " FINAL")]
t = time.time()
for name, src, fin in views:
    subprocess.run(["tools/ch",
        "CREATE OR REPLACE VIEW %s AS SELECT * EXCEPT generation FROM %s%s WHERE generation = $G" % (name, src, fin)],
        check=True, capture_output=True, env=env)
print("%.1f" % ((time.time() - t) * 1000))
PY
done | sort -n | awk '{a[NR]=$1} END {printf "   n=%d  min %s ms  median %s ms  max %s ms  (4 statements, incl. HTTP round trips)\n", NR, a[1], a[int((NR+1)/2)], a[NR]}'
echo "   window during which tiers disagree: the whole span above — a reader"
echo "   landing inside it sees some tiers on the new generation and some on the old."
echo

# Leave gp_pin in its specified shape: the pointer, not the literal.
for pair in "session_intervals|gen_session_intervals| FINAL" "cc_minute_delta|gen_cc_minute_delta|" \
            "cc_hour_agg|gen_cc_hour_agg| FINAL" "cc_user_minute|gen_cc_user_minute| FINAL"; do
  name="${pair%%|*}"; rest="${pair#*|}"
  ch "CREATE OR REPLACE VIEW ${name} AS SELECT * EXCEPT generation FROM ${rest%%|*}${rest#*|}
      WHERE generation = (SELECT generation FROM v_active_generation)" >/dev/null
done
echo "restored: gp_pin reads through the control-table pointer"
