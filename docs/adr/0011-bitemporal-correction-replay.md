# ADR 0011 — Expose correction state as of a logical finalizer run

> **Summary:** A concurrency value has two relevant times: the viewer event time and the run sequence
> at which the system incorporated it. Keep raw event time immutable and expose serving corrections as
> of a finalizer run through `--as-of-run`; the ordinary query remains the latest run. This allows late
> corrections to be explained without copying daily snapshots. Status: accepted, 2026-08-01.

**Status** Accepted · 2026-08-01

## Decision

`session_delta_correction_stage` already stores a complete target correction per session marker and
`run_sequence` is a logical time. Serving queries select published runs at or below an optional requested
sequence, then choose `argMax(correction_delta, run_sequence)` for each marker. `UInt64` maximum is the
normal current-state query; `tools/query-concurrency.sh --as-of-run N` is a forensic query.

## Consequences

- A late event can be demonstrated as a precise difference between two visible states rather than a vague
  claim that the dashboard "eventually corrected" itself.
- This is not a raw-data time-travel system: the bootstrap baseline is the initial serving belief and raw
  facts remain immutable. It is scoped to correction history, which keeps query cost bounded.
- Retention of correction-stage rows and run logs becomes an audit-retention policy. Expiring them removes
  the ability to reconstruct past serving belief, though not current correctness.
