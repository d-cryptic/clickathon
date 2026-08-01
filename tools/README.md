# tools/

> **Summary:** Scripts the agent built to make its own job easier. When a manual sequence repeats
> three times, it becomes a script here. Everything reads `.env`.

| Tool | Does |
|---|---|
| `fetch_data.sh [--force\|--verify]` | download the provided CSVs into `data/`, sha256-pinned. Run this before `load.sh` |
| `ch [-c] "SQL"` | run a query — local by default, `-c` for Cloud |
| `stats "SQL"` | run a query and print `X-ClickHouse-Summary` (rows/bytes/ms) — no `FLUSH LOGS` |
| `load.sh [raw.csv] [content.csv]` | load the datasets, converting epoch **millis** → `DateTime64(3)` |
| `build-model.sh` | **the RECOMPUTE path.** Rebuild the model in order: intervals -> deltas -> views, then reconcile. TRUNCATEs first — deltas double if you do not |
| `publish.sh --database N [--loop S]` | **the INCREMENTAL path** — one publication batch. Claims the sessions that received events since its cursor, re-derives only those, appends `-deltas(old) + deltas(new)`. Never truncates. `--sessions a,b` forces a correction; `--status` prints freshness. Refuses `sonyliv` unless `PUBLISH_ALLOW_PROD=1`. See [ADR 0013](../docs/adr/0013-continuous-publication-by-incremental-finalizer.md) |
| `publish-test.sh` | proves the above: builds through the incremental path, lands three shapes of late arrival including a 46-minute-late straggler, and compares against a from-scratch rebuild on every minute. Two scratch databases, `sonyliv` read-only. Writes `evidence/publish.txt`. ⚠ **requires `apply-sql.sh --database`, which lands with wave 1** |

| `reconcile.sh` | **THE GATE** — recompute concurrency from `ev_raw` and compare. Exits 1 on any mismatch; writes `evidence/reconcile.txt` |
| `apply-sql.sh [file...]` | apply `sql/*.sql` to local or `TARGET=cloud`. initdb only runs on first boot; Cloud has no mount at all |
| `clickstack-bootstrap.sh` | headless ClickStack setup; prints the OTLP ingestion key |
| `clickstack-sources.sh` | point the SELF-HOSTED HyperDX at our concurrency views. Idempotent |
| `clickstack-cloud.sh` | provision the HyperDX built into ClickHouse Cloud — sources, dashboard, saved searches — via the Cloud API. Idempotent |
| `../evidence/capture.sh` | the evidence harness — parts, compression, pruning, latency, MV cost |
| `../demo/chaos.sh <beat>` | demo fault injection (`stall_mv`, `stall_ingest`, …) |
