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
| `dictGet` vs `LEFT JOIN` on a small dimension | **3.7× less memory** — reproduced. The **34× time** figure did NOT reproduce; see the note below |
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


## Correction — the dictGet "34×" figure (2026-08-01)

Re-measured on this workload while building `sql/80_content.sql`, against `content_dim` (33,464 rows):

| Scale | Metric | JOIN | dictGet |
|---|---|---|---|
| `ev_raw` (905,558 rows) | elapsed, median of 3 | 35.6 ms | 19.9 ms — **1.8×** |
| `ev_raw` | memory | ~26 MB | 7.56 MB — **3.7×** |
| `cc_minute_delta` (24,951 rows — the views' real workload) | elapsed | 12.8 ms | 9.8 ms — **1.3×** |

> **Row count as measured**, at `34c3f05`. `cc_minute_delta` now holds **28,074** rows (ADR 0008 added
> dimensions, ADR 0009 redistributed tuples). The timings above have **not** been re-run at the new
> row count and are left as measured — this file is for facts, and a re-scaled guess is not one. The
> conclusion is unchanged either way: at single- to double-digit ms, wall clock is round-trip
> dominated, so a 12% row increase cannot rehabilitate a 34× claim.

**The memory ratio reproduces almost exactly.** The 34× *time* multiplier does not, at this scale:
wall clock here is single- to double-digit ms and round-trip dominated, and the JOIN's extra cost is
mostly the 3.7% additional rows read from the dimension side. The advantage is real and directionally
consistent, and it grows with table size — but quoting 34× for this data would be quoting a number
our own query log does not support.

Kept as a standing lesson: a figure inherited from a different dataset is a hypothesis, not a
verified fact, and this file is specifically for facts.

## Correction — a dictionary layout trap not previously recorded (2026-08-01)

A simple-key `LAYOUT(HASHED())`, `FLAT()` or `CACHE()` dictionary **cannot serve a negative key via
`dictGet`**, regardless of the declared column type — they key on `UInt64` internally. `content_dim`
contains `content_id = -987654322` (DATA_DICTIONARY trap 5). The dictionary loads all 33,464 elements
without complaint and then throws on lookup:

```
Code: 70. Value in column Int64 cannot be safely converted into type UInt64
```

`LAYOUT(COMPLEX_KEY_HASHED())` with `dictGet(..., tuple(content_id))` is required. `FLAT` was never
viable regardless: it allocates an array sized to the maximum key, and the maximum here is
2,078,179,327.
