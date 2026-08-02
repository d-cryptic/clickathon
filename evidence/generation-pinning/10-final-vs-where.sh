#!/usr/bin/env bash
# 10-final-vs-where.sh — the reason ADR 0023 rejected generation gating, tested
# both ways, plus the trap that replaces it.
#
# ADR 0023 §"Why generation_id is rejected", item 3:
#   "FINAL resolves BEFORE WHERE. An uncommitted newer row does not sit
#    invisibly behind a filter: it REPLACES the committed row at read time, and
#    the generation filter then discards the survivor, leaving no row — worse
#    than the lag it was meant to hide."
#
# That is exactly right for a generation carried as PAYLOAD, and exactly wrong
# for a generation carried in the SORT KEY. Rows of different generations are
# then different keys, so FINAL has nothing to collapse.
#
# Test 3 is the trap that arrives with the fix and is worth more attention than
# the fix: FINAL applied to a normal VIEW is a silent no-op.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=gp_probe
ch() { env -u CH_DATABASE CH_DATABASE_LOCAL="$DB" tools/ch "$1"; }
env -u CH_DATABASE CH_DATABASE_LOCAL=default tools/ch "CREATE DATABASE IF NOT EXISTS $DB" >/dev/null

echo "server: $(ch "SELECT version() FORMAT TSVRaw")"
echo

# Two tables, same rows, same engine, same version column. The ONLY difference
# is whether `generation` is in the ORDER BY.
ch "CREATE OR REPLACE TABLE payload_gen (k UInt32, generation UInt32, v Int64, computed_at UInt64)
    ENGINE = ReplacingMergeTree(computed_at) ORDER BY (k)" >/dev/null
ch "CREATE OR REPLACE TABLE keyed_gen   (generation UInt32, k UInt32, v Int64, computed_at UInt64)
    ENGINE = ReplacingMergeTree(computed_at) PARTITION BY generation ORDER BY (generation, k)" >/dev/null

# generation 1 is COMMITTED (v = 100). generation 2 is a build in flight (v = 999)
# whose rows have already landed. Separate inserts, so they are separate parts —
# which is the state a reader actually races against.
ch "INSERT INTO payload_gen VALUES (7, 1, 100, 1)" >/dev/null
ch "INSERT INTO payload_gen VALUES (7, 2, 999, 2)" >/dev/null
ch "INSERT INTO keyed_gen   VALUES (1, 7, 100, 1)" >/dev/null
ch "INSERT INTO keyed_gen   VALUES (2, 7, 999, 2)" >/dev/null

echo "TEST 1 — generation as PAYLOAD (ADR 0023's rejected design)"
echo "   SELECT ... FROM payload_gen FINAL WHERE generation = 1   (want: 1 row, v=100)"
printf '   got: %s\n' "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM payload_gen FINAL WHERE generation = 1 FORMAT TSVRaw")"
echo "   -> FINAL collapsed the two generations on key (k) and kept the newer one;"
echo "      the WHERE then discarded it. ADR 0023's objection reproduced exactly."
echo

echo "TEST 2 — generation LEADING the sort key (ADR 0034)"
echo "   SELECT ... FROM keyed_gen FINAL WHERE generation = 1     (want: 1 row, v=100)"
printf '   got: %s\n' "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM keyed_gen FINAL WHERE generation = 1 FORMAT TSVRaw")"
printf '   and the in-flight generation, asked for by name: %s\n' \
  "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM keyed_gen FINAL WHERE generation = 2 FORMAT TSVRaw")"
echo "   -> (1,7) and (2,7) are different keys. FINAL has nothing to collapse."
echo

echo "TEST 3 — THE TRAP: FINAL over a normal VIEW is a SILENT no-op"
# Two rows for the same key inside ONE generation — a re-derivation superseding
# an earlier one, which is the whole reason these tiers are ReplacingMergeTree.
ch "INSERT INTO keyed_gen VALUES (1, 9, 10, 1)" >/dev/null
ch "INSERT INTO keyed_gen VALUES (1, 9, 20, 2)" >/dev/null
ch "CREATE OR REPLACE VIEW v_no_final AS SELECT * EXCEPT generation FROM keyed_gen WHERE generation = 1" >/dev/null
ch "CREATE OR REPLACE VIEW v_has_final AS SELECT * EXCEPT generation FROM keyed_gen FINAL WHERE generation = 1" >/dev/null
printf '   base table, FINAL, k=9                    -> %s   (correct: v=20)\n' "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM keyed_gen FINAL WHERE generation = 1 AND k = 9 FORMAT TSVRaw")"
printf '   view WITHOUT final, reader says FINAL     -> %s   <-- WRONG, and silent\n' "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM v_no_final FINAL WHERE k = 9 FORMAT TSVRaw")"
printf '   view WITH final, reader says nothing      -> %s   (correct)\n' "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM v_has_final WHERE k = 9 FORMAT TSVRaw")"
printf '   view WITH final, reader ALSO says FINAL   -> %s   (correct; outer FINAL is inert)\n' "$(ch "SELECT concat(toString(count()), ' row(s), v=', toString(sum(v))) FROM v_has_final FINAL WHERE k = 9 FORMAT TSVRaw")"
echo
echo "   -> No error, no warning: FINAL on a view is dropped. Every pinned base"
echo "      view over a Replacing tier must therefore carry FINAL ITSELF, and"
echo "      downstream FINAL can no longer be trusted to mean anything."
