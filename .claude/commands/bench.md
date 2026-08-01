---
description: Run the benchmark query set and capture latency + bytes read as evidence.
---
Run every query in `evidence/benchmark/*.sql` against the current serving layer and capture evidence.
The whole procedure below is scripted: `tools/bench.sh` does it end to end and writes
`evidence/bench.txt` + `evidence/benchmark/results/`. Warm the Cloud service first — it
auto-suspends, and the first query after idle has been measured at 29.3 s.

For each query:
- run it 3 times, report median duration
- capture `read_rows` and `read_bytes` from `X-ClickHouse-Summary` (no `SYSTEM FLUSH LOGS` needed)
- capture `EXPLAIN indexes = 1` granule pruning

Write a single table to `evidence/bench.txt`: query | median ms | rows read | bytes read | granules.
Commit it. Judges look at **what the query reads**, not only how fast it returns — so bytes read is
the column that matters most.

The benchmark set covers: peak and average concurrency × minute/hour/day grain × dimension filters
(platform, country, content, video type). If `evidence/benchmark/` is empty, generate those shapes
from the statement and say clearly that they are our reconstruction, not the official set.
