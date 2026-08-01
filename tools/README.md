# tools/

> **Summary:** Scripts the agent built to make its own job easier. When a manual sequence repeats
> three times, it becomes a script here. Everything reads `.env`.

| Tool | Does |
|---|---|
| `ch-run.sh --query …` / `--file …` | target-aware SQL executor; supports parameters and ClickHouse settings without printing credentials |
| `deploy-schema.sh` | creates the raw and serving schema on local or Cloud; intentionally does not create local-only users |
| `fetch_data.sh [--force\|--verify]` | download the provided CSVs into `data/`, sha256-pinned. Run this before `load.sh` |
| `ch [-c] "SQL"` | run a query — local by default, `-c` for Cloud |
| `stats "SQL"` | run a query and print `X-ClickHouse-Summary` (rows/bytes/ms) — no `FLUSH LOGS` |
| `load.sh [raw.csv] [content.csv]` | load the datasets, converting epoch **millis** → `DateTime64(3)` |
| `materialize.sh --replace` | explicitly rebuild the historical state-gated interval and hour-clipped delta spine |
| `bootstrap-finalizer.sh --replace` | creates and verifies the per-session marker baseline after historical materialization |
| `finalize.sh [--resume RUN_UUID]` | stages then publishes correction state for sessions touched since the ingestion checkpoint |
| `refresh-tail.sh [--tail-window-seconds N]` | publishes the exact bounded minute snapshot after the current finalizer run; default window is 900 seconds |
| `finalizer-status.sh` | reports source checkpoint, correction state, and whether the exact tail matches its current finalizer version |

`MODEL_VERSION` defaults to `state-gated-v1`; every run appends a deterministic fingerprint of the
state-machine, correction, and tail SQL. Change the label only with a historical rebuild followed by
`bootstrap-finalizer.sh --replace`; `finalize.sh` rejects a correction against a differently-versioned baseline.

The core loading, model, finalizer, tail, query, status, and raw-to-serving reconciliation commands honor `TARGET=local|cloud`
(default `local`). For a newly provisioned Cloud service: deploy the schema, then load, build, bootstrap,
finalize, and publish the tail. Run correctness probes against the same target only after the organiser
data and a real endpoint are available.

`materialize.sh --replace` refuses an empty `ev_raw` target before truncating derived tables. This protects
against a wrong Cloud database or failed load; the explicit `--replace` flag remains required.

```bash
TARGET=cloud tools/deploy-schema.sh
TARGET=cloud tools/load.sh
TARGET=cloud tools/materialize.sh --replace
TARGET=cloud tools/bootstrap-finalizer.sh --replace
TARGET=cloud tools/finalize.sh
TARGET=cloud tools/refresh-tail.sh
TARGET=cloud tools/finalizer-status.sh
TARGET=cloud tools/reconcile.sh
```
| `verify-model.sh` | checks hard-stop exclusion and sampled interval-to-delta reconstruction |
| `reconcile.sh` | rebuilds raw truth in temporary tables and compares five global minutes to the delta layer |
| `query-concurrency.sh --from … --to … [--summary] [--as-of-run N]` | serves a zero-filled minute curve or exact peak/average, with optional dimension filters and forensic correction time travel |
| `verify-query-summary.sh` | proves the summary’s peak/average/integral agrees with its minute curve for unfiltered, platform, content, and video-type shapes |
| `audit-data.sh [cutoff]` | target-aware audit of duplicate identity, dimension drift, timestamp ties, terminal leakage, and synthetic open sessions |
| `validate-source-contract.sh` | fails before materialization on ambiguous lifecycle identity, invalid timestamps, unknown event types, dimension ties, or missing content references |
| `truncation-test.sh [cutoff]` | replays the model over a temporary event-time cut and proves open sessions appear in the staged exact tail without durable writes |
| `synthetic-edge-test.sh` | asserts adversarial foreground-state, duplicate, handoff, error, and minute-boundary behavior using temporary tables |
| `clickstack-bootstrap.sh` | headless ClickStack setup; prints the OTLP ingestion key |
| `../evidence/capture.sh` | the evidence harness — parts, compression, pruning, latency, MV cost |
| `../demo/chaos.sh <beat>` | demo fault injection (`stall_mv`, `stall_ingest`, …) |
