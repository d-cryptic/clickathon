# Worksheet — 2026-08-02 · new filter columns land in `extra`, loudly (T1 / ADR 0024)

> **Summary:** `tools/load.sh` now diffs the incoming header before loading a row: NEW columns are
> announced and carried into `ev_raw.extra` / `content_dim.extra` `Map(LowCardinality(String),
> String)` (queryable same-day, no migration); MISSING columns refuse unless named in
> `--allow-missing`; `event_timestamp`/`video_session_id`/`content_id` can never be defaulted.
> 13-column path proven fingerprint-identical to the pre-0024 loader; empty maps cost +0.48%
> compressed, populated 2-key maps +3.6%, load time unchanged; reconcile PASSes on a model built
> from a new-column file. 30 assertions in `evidence/schema-drift/probes.txt`. ADR 0024 written.

## Goal

T1 from the worktree queue: the judges said new filter columns WILL appear; the loader silently
dropped them (and silently blanked removed ones). Detect loudly, carry unknowns, keep the known 13
byte-identical, make a new dimension filterable end to end, record cost in ADR 0024. Scratch only.

## What changed (ownership: `tools/load.sh`, `sql/00_schema.sql`, ADR 0024)

- `sql/00_schema.sql` — `extra Map(LowCardinality(String), String)` on `ev_raw` + `content_dim`;
  `ALTER … ADD COLUMN IF NOT EXISTS` after each CREATE so the file converges pre-0024 databases;
  corrected the measured-false `non_replicated_deduplication_window` idempotency comment (bug 8).
- `tools/load.sh` — `analyse_header()` (python csv, already a dep): header diff, loud report,
  rename hints, refusals for duplicate/non-identifier headers; builds `input()` structure +
  SELECT list + insert column list from the actual header; `--allow-missing a,b` flag; guard that
  refuses new-column loads into pre-0024 tables BEFORE `--replace` truncates, printing the ALTER.
- `evidence/schema-drift/` — `capture.sh` (30 assertions, pre-change loader from git `7c74581`),
  `probes.txt`, `worked-example.sql`, `raw-fallback-network.sql`.
- `docs/adr/0024-carry-unknown-filter-columns-in-an-extra-map.md`.

## Verified (all local, scratch DBs `adr0024cap_*`, graded DB untouched)

- 13-col fingerprint (order-independent cityHash64 over all columns) identical old vs new loader:
  `13118056588632894114`; content_dim likewise. Reorder probe hash-identical to straight load.
- Reconcile gate on a model built from a file carrying 2 unknown columns: PASS, 17,028 minutes,
  0 mismatches, peak 2,917 — the model neither reads nor is perturbed by `extra`.
- Worked example: `extra['device_type']` series == platform-derived series on all 3,732 active
  minutes; deterministic (modal `(platform, device_type)` pair, ADR 0009 rule — `anyLast()` made
  per-device peaks drift between runs and was replaced).
- Tier boundary measured: function-of-a-key dim served from `cc_minute_delta` in 0.2 s (peak 645,
  exact); independent dim via raw recompute 0.23 s; promotion path documented, keys NOT changed.

## Open questions / next step

- `tools/load-guard-test.sh` (held, not mine) exercises Cloud scratch DBs — this session is
  prohibited from ANY Cloud write, so its cloud cases were replicated locally in capture.sh §4–§8
  instead. A cloud-allowed session should run the full guard test once after merge.
- The graded `sonyliv` database is pre-0024: its owner can converge it with the one ALTER in the
  ADR (metadata-only) whenever a drop with new columns is expected.
- Promotion of a proven-important `extra` key to a first-class tier dimension remains a separate
  decision (ADR 0024 §boundary).
- `tools/README.md`'s load.sh row and DATA_DICTIONARY's traps section should mention the shape
  check — both files are outside this session's ownership list (several agents running), so the
  same-commit doc rule is deliberately deferred to the merge owner. The ADR and `load.sh --help`
  carry the full behaviour meanwhile.

## How to verify

`bash evidence/schema-drift/capture.sh` — 30 assertions, exits non-zero on any FAIL, drops its
scratch DBs on exit.

## Incident, disclosed

`CH_DATABASE_LOCAL=adr0024_drift tools/build-model.sh` targeted local `default` anyway —
build-model sources `.env` with `set -a` AFTER reading the environment (the bug-11 pattern
`tools/load.sh` fixed), so `.env`'s `CH_DATABASE_LOCAL=default` won. Its step 1 TRUNCATEd
`default.session_intervals` (then died on a schema mismatch; no other table touched, `ev_raw` /
`content_dim` / `cc_minute_stateless` intact). `default` is the local dev copy, rebuildable by the
current pipeline; the graded DB was never involved. Filed in AGENT_FEEDBACK; build-model.sh is not
in this session's ownership so the fix is left to its owner.
