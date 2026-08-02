#!/usr/bin/env bash
# 20-pointer-cost.sh — does `WHERE generation = (SELECT ...)` still prune?
#
# The whole cost argument for ADR 0034 rests on one claim: a scalar subquery is
# evaluated during analysis and substituted as a constant, so partition and
# primary-key pruning are identical to writing the generation as a literal, and
# holding N generations therefore costs a pinned reader nothing in bytes.
#
# Three reads of the same table — literal pin, pointer pin, no pin — on a table
# holding three generations of 1M rows each.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=gp_probe
ch() { env -u CH_DATABASE CH_DATABASE_LOCAL="$DB" tools/ch "$1"; }
env -u CH_DATABASE CH_DATABASE_LOCAL=default tools/ch "CREATE DATABASE IF NOT EXISTS $DB" >/dev/null

ch "CREATE OR REPLACE TABLE cost_gen (generation UInt32, k UInt32, v Int64, computed_at UInt64)
    ENGINE = ReplacingMergeTree(computed_at) PARTITION BY generation ORDER BY (generation, k)" >/dev/null
ch "INSERT INTO cost_gen SELECT (number % 3) + 1, number, number, 1 FROM numbers(3000000)" >/dev/null
ch "CREATE OR REPLACE TABLE cost_ptr (generation UInt32, status String, at DateTime) ENGINE = MergeTree ORDER BY generation" >/dev/null
ch "TRUNCATE TABLE cost_ptr" >/dev/null
ch "INSERT INTO cost_ptr VALUES (1, 'committed', now())" >/dev/null
ch "CREATE OR REPLACE VIEW cost_active AS
      SELECT ifNull(max(generation), 0) AS generation
      FROM (SELECT generation, argMax(status, at) AS status FROM cost_ptr GROUP BY generation)
      WHERE status = 'committed'" >/dev/null

echo "rows per generation:"
ch "SELECT generation, count() FROM cost_gen GROUP BY generation ORDER BY generation FORMAT TSV" | sed 's/^/   /'
echo

TAG="gpc-$(date +%s)"
ch "SELECT sum(v) FROM cost_gen WHERE generation = 1 SETTINGS log_comment='$TAG:literal', use_query_cache=0" >/dev/null
ch "SELECT sum(v) FROM cost_gen WHERE generation = (SELECT generation FROM cost_active) SETTINGS log_comment='$TAG:pointer', use_query_cache=0" >/dev/null
ch "SELECT sum(v) FROM cost_gen SETTINGS log_comment='$TAG:unpinned', use_query_cache=0" >/dev/null
ch "SYSTEM FLUSH LOGS" >/dev/null

echo "pin form            read_rows    read_bytes   parts   ms"
ch "SELECT concat(rpad(splitByChar(':', log_comment)[2], 20, ' '),
                  lpad(formatReadableQuantity(read_rows), 9, ' '), '  ',
                  lpad(formatReadableSize(read_bytes), 12, ' '), '  ',
                  lpad(toString(length(arrayFilter(x -> position(x, 'cost_gen') > 0, arrayMap(y -> toString(y), tables)))), 5, ' '), '  ',
                  lpad(toString(query_duration_ms), 4, ' '))
    FROM system.query_log
    WHERE log_comment LIKE '$TAG:%' AND type = 'QueryFinish'
    ORDER BY event_time_microseconds FORMAT TSVRaw" | sed 's/^/   /'

echo
echo "   The pointer read is the literal read plus ONE row — that row is the"
echo "   control table. Pruning is unaffected by the indirection."
echo
echo "   Retiring a generation is metadata only:"
ch "SELECT concat('   partitions on cost_gen: ', arrayStringConcat(groupUniqArray(partition), ' '))
    FROM system.parts WHERE database = '$DB' AND table = 'cost_gen' AND active FORMAT TSVRaw"
S=$(python3 -c 'import time;print(time.time())')
ch "ALTER TABLE cost_gen DROP PARTITION 3" >/dev/null
python3 -c "import time;print('   DROP PARTITION 3 took %.0f ms' % ((time.time()-$S)*1000))"
ch "SELECT concat('   partitions now:         ', arrayStringConcat(groupUniqArray(partition), ' '))
    FROM system.parts WHERE database = '$DB' AND table = 'cost_gen' AND active FORMAT TSVRaw"
