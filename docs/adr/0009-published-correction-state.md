# ADR 0009 — Publish correction snapshots, not correction increments

> **Summary:** Serving starts from the historical signed-delta baseline and overlays the latest published
> per-session correction marker. Corrections are complete snapshots keyed by session/dimensions/minute,
> selected with `argMax` over an immutable run sequence; zero is a tombstone. A run is invisible before
> publication, so a failed finalizer never exposes half a session update. Status: accepted, 2026-08-01.

**Status** Accepted · 2026-08-01

## Decision

Use `session_delta_correction_stage` as a versioned state ledger rather than an additive correction ledger.
The serving query reads `cc_minute_delta UNION ALL current_correction_state`, groups the marker deltas, then
uses the existing hour-local running sum. This keeps the hot query shape unchanged for the large baseline.

The marker key includes session id because a correction must replace a single session's contribution, not an
already-aggregated dimensional total. It contains the dimensional values because a late dimension handoff can
move one session from one dashboard bucket to another. Tombstone rows make an old correction disappear if a
later re-derivation returns to the bootstrap value.

`phase` is an ordered enum. Consumers select `max(phase)` per run instead of using an `argMax` over
`recorded_at`, so two phase records sharing a millisecond cannot make visibility nondeterministic.

## Why

The system has one atomic property we can use safely: a successful single-table insert is visible as a whole.
It does not have a general production-ready transaction joining the stage table, aggregate table, and run log.
Publishing the run only after staging converts this into an explicit visibility barrier. It is simpler to audit
than mutation queues and does not require forcing merges or `FINAL` on the aggregate serving path.

## Verification contract

The bootstrap command proves that aggregating `session_delta_base` produces the existing `cc_minute_delta`.
The late-arrival test inserts a background marker into a long active session, finalizes it, and checks the
served curve against an independent full derivation from raw. A resumed run must yield the same curve as its
first execution.

## Model-version fence

The correction is meaningful only relative to the exact state-machine semantics that built the baseline.
`MODEL_VERSION` is stored on every run with a deterministic fingerprint of the state-machine, correction,
and tail SQL. `tools/finalize.sh` rejects a baseline with a different version, forcing an intentional
historical rematerialization and bootstrap when thresholds, state precedence, or dimension semantics change.
This prevents a syntactically successful but semantically mixed ledger even when an operator forgets to
rename the human release label.
