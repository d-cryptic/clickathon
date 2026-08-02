# Worksheet — 2026-08-01 · one command, one database (Q16 / ADR 0018)

> **Summary:** Unified target→database resolution across Go, `tools/ch`, and `.env`: cloud reads
> `CH_HOST`+`CH_DATABASE`, local reads `CH_LOCAL_URL`+`CH_DATABASE_LOCAL`, both required, always
> sent explicitly, environment beats `.env`, missing config dies naming the variable. Column-diffed
> local `default` vs Cloud `sonyliv` (4 drifted columns: `uniq` vs `uniqExact` ×2, `UInt64` vs
> `Int64` ×2), rebuilt the local tables from git SQL + backfill — 0 drift remains, 0/3,860 minutes
> disagree with `ev_raw`. Cloud was touched by READ queries only. ADR 0018 written; proof in
> `evidence/target-resolution.txt`; `make ci` green (lint 0 issues, race tests pass).

## Goal

Q16: one resolution path every layer shares; `TARGET=local`/`TARGET=cloud` each resolve to exactly
one host and one database; misconfiguration fails loudly; local/Cloud schema agree where the
difference is not deliberate; ADR 0018 records the rule and the intentional-vs-drift split.

## What changed

- `tools/ch` — sends `database=` on BOTH branches (was: server default locally); per-target
  variables with no cross-target fallback; environment captured before `.env` (bug-11 fault);
  `.env` resolved from the repo root, not the CWD; loud `die` messages that name the fix.
- `internal/config/config.go` — `loadLocal` requires `CH_DATABASE_LOCAL` + `CH_PASSWORD_LOCAL` and
  never reads `CH_DATABASE`; `loadCloud` requires `CH_DATABASE`. Package doc states the rule.
- `internal/config/config_test.go` — `TestLoadLocalNeverReadsCloudDatabase` pins the 404 bug;
  plus local-resolution and cloud-requires-database cases.
- `.env.example` — `CH_DATABASE_LOCAL=default` added as REQUIRED with the rule explained.
- `docs/GO.md` — summary + conventions updated to the per-target rule.
- Local server state (not git): dropped and rebuilt `default.cc_minute_stateless`, `mv_stateless`,
  `cc_minute_delta` from `sql/10_intervals.sql`; backfilled stateless from `ev_raw` (91,292 rows).
- `docs/adr/0018-one-target-one-database-no-cross-target-fallback.md`, `evidence/target-resolution.txt`.

## Decisions

1. **Strict per-target variables, not a smarter fallback chain.** The graded-database incident was a
   fallback doing its job "helpfully". Local borrowing `CH_DATABASE` is the exact bug; tests pin it.
2. **`uniq` drift repaired by rebuild, not ALTER** — aggregate state types cannot be altered in
   place; the drop/re-apply/backfill path is the one `sql/10_intervals.sql` itself documents.
3. **Did NOT touch `tools/apply-sql.sh`/`tools/load.sh`** (other workstream): their local chains
   still fall back to `CH_DATABASE` after `CH_DATABASE_LOCAL`. Dead now that `.env` defines
   `CH_DATABASE_LOCAL`, but the steps should be deleted by their owner — flagged in ADR 0018.

## How to verify

- `devbox run -- make ci` — green.
- `tools/ch "SELECT currentDatabase()"` → `default`; `tools/ch -c "…"` → `sonyliv` (read-only).
- `mv .env /tmp; tools/ch "SELECT 1"` → dies naming `CH_DATABASE_LOCAL`; restore `.env`.
- Rerun the `system.columns` diff in `evidence/target-resolution.txt` §4 → 0 rows.

## Open questions / next step

- Operators of `apply-sql.sh`/`load.sh`: delete the local→`CH_DATABASE` fallback steps (ADR 0018,
  "Known residue"). No Cloud-side change is needed — `TARGET=cloud` resolution is unchanged.
- Everyone's `.env` needs `CH_DATABASE_LOCAL=default` added once (`.env.example` shows where).
