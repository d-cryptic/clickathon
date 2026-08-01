#!/bin/bash
# Evidence harness. set -euo pipefail is REQUIRED: plain `set -e` does NOT fire inside
# `cmd | tee`, so the script reports success while writing empty files.
set -euo pipefail
CONTAINER="${CH_CONTAINER:-ch}"
DB="${CH_DB:-default}"
CH() { docker exec -i "$CONTAINER" clickhouse-client -q "$1" < /dev/null; }
mkdir -p evidence

CH "SYSTEM FLUSH LOGS"          # log tables are buffered

echo "== part types (compression is 0 for COMPACT) =="
CH "SELECT table, part_type, count() AS parts, formatReadableSize(sum(data_uncompressed_bytes)) AS raw
    FROM system.parts WHERE active AND database='$DB' GROUP BY table, part_type FORMAT PrettyCompact" \
  | tee evidence/parts.txt

echo "== compression, per column =="
CH "SELECT table, name, formatReadableSize(data_compressed_bytes) AS compressed,
      formatReadableSize(data_uncompressed_bytes) AS raw,
      round(data_uncompressed_bytes / nullIf(data_compressed_bytes,0), 1) AS ratio
    FROM system.columns WHERE database='$DB' AND data_compressed_bytes > 0
    ORDER BY data_uncompressed_bytes DESC LIMIT 25 FORMAT PrettyCompact" | tee evidence/compression.txt

echo "== granule pruning on the main query =="
[ -f evidence/main_query.sql ] && \
  CH "EXPLAIN indexes = 1 $(cat evidence/main_query.sql)" | tee evidence/explain_indexes.txt

echo "== query latency =="
CH "SELECT substring(normalizeQuery(any(query)),1,60) AS q, count() AS runs,
      quantiles(0.5,0.9)(query_duration_ms) AS p50_p90,
      formatReadableSize(avg(read_bytes)) AS avg_read
    FROM system.query_log WHERE type='QueryFinish' AND event_date=today()
    GROUP BY normalized_query_hash ORDER BY runs DESC LIMIT 10 FORMAT PrettyCompact" \
  | tee evidence/latency.txt

echo "== materialized view cost =="
if [ "$(CH "EXISTS TABLE system.query_views_log")" = "1" ]; then
  CH "SELECT view_name, count() AS fires, sum(written_rows) AS rows, avg(view_duration_ms) AS avg_ms
      FROM system.query_views_log WHERE event_date=today()
      GROUP BY view_name ORDER BY fires DESC FORMAT PrettyCompact" | tee evidence/mv_cost.txt
else
  echo "  (no MV has fired yet - system.query_views_log does not exist)" | tee evidence/mv_cost.txt
fi
echo "== ALL SECTIONS COMPLETED =="
