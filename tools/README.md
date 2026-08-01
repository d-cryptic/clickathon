# tools/

> **Summary:** Scripts the agent built to make its own job easier. When a manual sequence repeats
> three times, it becomes a script here. Everything reads `.env`.

| Tool | Does |
|---|---|
| `fetch_data.sh [--force\|--verify]` | download the provided CSVs into `data/`, sha256-pinned. Run this before `load.sh` |
| `ch [-c] "SQL"` | run a query — local by default, `-c` for Cloud |
| `stats "SQL"` | run a query and print `X-ClickHouse-Summary` (rows/bytes/ms) — no `FLUSH LOGS` |
| `load.sh [raw.csv] [content.csv]` | load the datasets, converting epoch **millis** → `DateTime64(3)` |
| `build-model.sh` | rebuild the model in order: intervals -> deltas -> views, then reconcile. TRUNCATEs first — deltas double if you do not |
| `reconcile.sh` | **THE GATE** — recompute concurrency from `ev_raw` and compare. Exits 1 on any mismatch; writes `evidence/reconcile.txt` |
| `apply-sql.sh [file...]` | apply `sql/*.sql` to local or `TARGET=cloud`. initdb only runs on first boot; Cloud has no mount at all |
| `clickstack-bootstrap.sh` | headless ClickStack setup; prints the OTLP ingestion key |
| `clickstack-sources.sh` | point the SELF-HOSTED HyperDX at our concurrency views. Idempotent |
| `clickstack-cloud.sh` | provision the HyperDX built into ClickHouse Cloud — sources, dashboard, saved searches — via the Cloud API. Idempotent |
| `../evidence/capture.sh` | the evidence harness — parts, compression, pruning, latency, MV cost |
| `scale-test.sh [N...]` | **THE SCALE EVIDENCE** — run the model at 1x/10x/100x the provided file and write `evidence/scale.txt`. Local only, own scratch databases, drops them after. `KEEP=1` to inspect |
| `scale-gen.sql` | fits the generator's vocabularies (`gen_lut`, `gen_content`, `gen_ev`, `gen_start`) off the **real** file. Driven by `scale-test.sh`, not run by hand |
| `scale-load.sql` | the generator itself — `INSERT ... SELECT FROM numbers_mt`, all server-side. Deterministic: every draw is `cityHash64(session, salt)`, so `(S, SEED)` regenerates the same stream |
| `scale-fidelity.sql` | real vs synthetic on the shape metrics the model reads. This is what makes the scale timings falsifiable |
| `../demo/chaos.sh <beat>` | demo fault injection (`stall_mv`, `stall_ingest`, …) |
