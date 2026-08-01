# ADR 0012 — Fence the exact tail to its correction version

> **Summary:** The mutable tail is a complete, short, exact minute snapshot produced after a published
> finalizer run. Serving selects it only when its recorded finalizer sequence is the currently selected
> correction sequence; otherwise it reads the fully correct delta-plus-correction ledger. This eliminates
> stale-tail masking without requiring multi-table transactions or a heuristic heartbeat lease.

**Status** Accepted · 2026-08-01

## Context

Open sessions need a fresh serving path, but the measured source proves that a stateless heartbeat lease
would count backgrounded and paused activity. The finalizer already derives the correct event-time state
for touched sessions and publishes a correction version. A tail rebuilt from an older correction version
is not safe: a late background marker may have changed the newest minutes after that snapshot was made.

## Decision

`refresh-tail.sh` stages one complete, bounded snapshot in `exact_tail_minute_stage`, then appends
`prepared → staged → published` records to `exact_tail_run_log`. The run records the finalizer sequence,
event-time watermark, source high-watermark, model version, and row count. The query chooses the latest
published tail only when `tail.finalizer_run_sequence = selected_finalizer_run_sequence`; otherwise it
uses the existing signed-delta baseline plus published correction overlay for every minute.

The snapshot stores non-zero leaf dimension minute values only. Within its recorded
`[event_watermark, tail_until]` range absence means zero; before or after that range, serving uses the
delta-plus-correction ledger. This range fence prevents a finite tail snapshot from turning arbitrary
later query minutes into false zeroes.
It is intentionally bounded (900 seconds by default) while the historical ledger remains compact signed
boundaries, so permanent storage never becomes a per-minute expansion of all session history.

## Consequences

- A crash before publication is invisible, as with the correction ledger.
- A new correction can only make the result use the conservative exact ledger; it cannot expose a stale
  hot value. Refreshing the tail restores the fast current path.
- `tools/truncation-test.sh` runs the real tail-stage SQL against temporary event-time-cut tables. At the
  10:30 cut it proves 75 served tail sessions equal 75 raw-derived active intervals, with no interval
  extending beyond the 60-second credit bound.
- The tail-window width remains an operational choice. The bulk CSV has no arrival telemetry, so 900
  seconds is a bounded demonstration default, not a production lateness percentile.
