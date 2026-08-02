---
name: ch-evidence
description: Capture defensible ClickHouse performance and correctness evidence - granule pruning, bytes read, compression, MV cost. Use when producing numbers for the deck or the submission.
---

# Capturing evidence that survives a judge

Numbers you cannot reproduce are worse than no numbers. Every figure in the deck must come from a
committed command.

## The stats shortcut
Every HTTP response carries `X-ClickHouse-Summary` with `read_rows`, `read_bytes`, `elapsed_ns`,
`memory_usage` — **no `SYSTEM FLUSH LOGS`, no second query**. `tools/stats "<sql>"` wraps it.
- Add `wait_end_of_query=1` if you also need `result_rows`/`result_bytes`; they are `0` otherwise.
- A **failed** query returns an all-zero summary — check the status, not just the header.

## Granule pruning
`EXPLAIN indexes = 1` → the `Granules: X/Y` line. That ratio is the whole sort-key story.

## Compression — the trap
`system.columns.data_compressed_bytes` reads **0 for COMPACT parts**. Compact parts keep all columns
in one file, so there is no per-column accounting. Threshold: `min_bytes_for_wide_part = 10485760`.
- Our tables set `min_bytes_for_wide_part = 0` so this works even on small loads.
- `system.parts_columns` is **not** a workaround — it repeats the *part* total on every column row.
- Capture compression **after** the full load, not at hour 2.

## MV cost
`system.query_views_log` does **not exist** until an MV has fired. Guard with
`EXISTS TABLE system.query_views_log` or the script dies.

## Always
`SYSTEM FLUSH LOGS` before reading any `system.*_log` — they are buffered. Label runs with
`SETTINGS log_comment='...'` so you can find them again.
