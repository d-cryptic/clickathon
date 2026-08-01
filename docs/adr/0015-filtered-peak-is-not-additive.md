# ADR 0015 — Do not roll up generic filtered peaks

> **Summary:** Signed deltas and concurrency integrals are additive across serving dimensions, but peak
> concurrency is not. A generic `cc_hour_agg` storing per-dimension `max` cannot answer an arbitrary
> filtered peak exactly. Keep the minute change-point path as peak authority; create only measured,
> explicitly scoped cuboids or additive integral rollups. Status: accepted, 2026-08-01.

**Status** Accepted · 2026-08-01

## Context

The problem asks for peak and average concurrency under optional platform, country, content, and video-type
filters. It is tempting to store one hourly row for each base dimension combination with `max(concurrency)`
and then sum it for a dashboard filter. That is incorrect whenever two groups peak in different minutes:

```
group A: [10, 0]  → max = 10
group B: [ 0, 9]  → max =  9
combined: [10, 9] → max = 10, not 19
```

No merge schedule or aggregate engine fixes that loss of alignment. The counterexample applies to any
pre-aggregation level that is finer than the query's requested grouping.

## Decision

- `cc_minute_delta` plus its hour-local running sum remains the exact authority for all filtered peaks.
- An integral (`sum of minute concurrency`) is additive; an hourly integral rollup may accelerate
  full-hour averages and totals after its own raw-vs-serving reconciliation.
- A precomputed peak is valid only for its **exact** filter cuboid and full-hour time range. Build one only
  after benchmark evidence identifies a small, stable set of cuboids worth the write amplification.
- A range with partial boundary hours still reads minute-level data for those boundaries. `video_type` is
  current-catalogue filtering, so a precomputed cuboid for it additionally needs an explicit dimension
  version policy.

## Consequences

- `cc_hour_agg (max + integral)` is not a generic next optimisation; only its additive fields are broadly
  reusable.
- The present minute-change-point read is deliberately retained until Cloud benchmark shapes and bytes-read
  measurements demonstrate a real need for a particular exact cuboid.
- The serving contract remains exact rather than silently returning a sum of unrelated maxima.
