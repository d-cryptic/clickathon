# VERIFIED — facts we executed, not read

> **Summary:** Every claim here was **run** against ClickHouse 26.7.1.1315, ClickStack, Langfuse,
> LibreChat and the ClickHouse MCP server over 30–31 Jul 2026, producing 57 corrections to
> documentation. This file is the short list that changes what you type. **Read it before trusting any
> ClickHouse claim, including your own memory.** Full log lives in the research repo
> (`clickathon/docs/28-verified-behaviour.md`). If something here turns out wrong on Cloud, fix it
> here in the same commit.

## Things that will silently waste your time

| # | Fact | Consequence |
|---|---|---|
| 1 | The server image **disables network access for `default`** unless `CLICKHOUSE_USER` *and* `CLICKHOUSE_PASSWORD` are set | `Code: 194` on every query |
| 2 | `${VAR}` in a **`.sql`** init file is **not interpolated** | user gets the literal string as its password |
| 3 | A `.env` feeds **compose's** substitution, not the container | var must also be under `environment:`, else **empty password** |
| 4 | `docker-entrypoint-initdb.d` runs **only on first boot** | iterate with `down -v`; plain `down` keeps the volume |
| 5 | **A failed init script does not stop the container** | status `Up`, `/api/health` `200`, schema half-applied |
| 6 | `readonly = 1` blocks the client setting `max_execution_time` | `Code: 164`; agents/MCP need `readonly = 2` + `MAX` constraints |
| 7 | `non_replicated_deduplication_window` defaults to **0** | insert dedup is **OFF** on plain MergeTree |
| 8 | `system.query_views_log` etc. **do not exist** until first used | guard with `EXISTS TABLE`; always `SYSTEM FLUSH LOGS` first |
| 9 | Per-column compression reads **0 for COMPACT parts** | set `min_bytes_for_wide_part = 0`, or load ≥10 MiB per part |
| 10 | `set -e` does **not** fire inside `cmd \| tee` | use `set -euo pipefail` or scripts lie about succeeding |
| 11 | `SYSTEM STOP VIEW` is a **refreshable**-MV command | on an incremental MV it is accepted and **does nothing**; use `DETACH`/`ATTACH` |

## 26.7 breaking changes, both confirmed

```sql
-- a plain column in an AggregatingMergeTree that is neither in the sort key nor an aggregate:
→ Code: 36. Column(s) `x` ... neither part of the sorting key nor aggregate measures
-- s3() with server-managed credentials:
→ Code: 497. S3 access from user queries is not allowed to use server-managed credentials
```

## Measured, on comparable data

| Technique | Effect |
|---|---|
| Entity-first sort key vs time-only | **122×** fewer rows read (5,000,000 → 40,960; granules 5/611) |
| `dictGet` vs `LEFT JOIN` on a small dimension | **34×** faster, 3.7× less memory |
| Rollup that sums a distinct count | **9× over-count** (45,000 vs a truth of 5,000) |
| Skip index on clustered vs spread values | 366× vs ~nothing |
| A `PROJECTION` on a badly-keyed table | recovers the good key's row count exactly |

## ClickStack (the OSS integration)

- Needs a **TTY** or it exits 129 after a clean boot.
- OTLP 4317/4318 **do not bind until a team exists**; registration is `POST /register/password` at the
  **root**, not `/api`. And the collector binds **late** — poll, don't sleep.
- Bundles its **own** ClickHouse **26.5.6**. Never build the project on it.
- Default TTL is **30 days**; `SeverityText` is stored **lower-cased**.
- One OTel emitter feeds ClickStack **and** Langfuse — same `trace_id` lands in both (verified).

## MCP

- Env names are `CLICKHOUSE_MCP_*`; `MCP_SERVER_TRANSPORT` is **silently ignored**.
- Exactly 3 tools: `list_databases`, `list_tables`, `run_query`. `run_chdb_select_query` needs the
  chdb extra installed, not just `CHDB_ENABLED=true`.
- The server enforces read-only **itself**: a write returns `Code: 164` even as a privileged user.
- stdio works on the host; it does **not** work inside the LibreChat container (no C compiler → `lz4`
  cannot build). Use `streamable-http` there, plus `mcpSettings.allowedAddresses`.
