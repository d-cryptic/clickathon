# tools/

> **Summary:** Scripts the agent built to make its own job easier. When a manual sequence repeats
> three times, it becomes a script here. Everything reads `.env`.

| Tool | Does |
|---|---|
| `ch [-c] "SQL"` | run a query — local by default, `-c` for Cloud |
| `stats "SQL"` | run a query and print `X-ClickHouse-Summary` (rows/bytes/ms) — no `FLUSH LOGS` |
| `load.sh [raw.csv] [content.csv]` | load the datasets, converting epoch **millis** → `DateTime64(3)` |
| `clickstack-bootstrap.sh` | headless ClickStack setup; prints the OTLP ingestion key |
| `../evidence/capture.sh` | the evidence harness — parts, compression, pruning, latency, MV cost |
| `../demo/chaos.sh <beat>` | demo fault injection (`stall_mv`, `stall_ingest`, …) |
