# 05 · "Publish continuously updated aggregates" — what actually satisfies it?

> **Summary:** `README_START_HERE.md` step 4 requires the pipeline to "publish continuously updated
> aggregates". Today only two of our six serving aggregates are real materialized views
> (`mv_stateless`, `mv_user_minute`); the graded core — `session_intervals`, `cc_minute_delta`,
> `cc_hour_agg` and the content views — is **batch-rebuilt** by `make model` (~11 s on Cloud), with
> incremental absorption *proven convergent* (row-for-row equal to a clean rebuild on all 1,578
> minutes, after fixing the `ReplacingMergeTree` versioning bug). WALKTHROUGH.md calls this "the
> biggest gap". Whether it *is* a gap depends entirely on what the judges accept as "continuous" —
> a true MV cascade is architecturally awkward for this model (interval derivation is a multi-pass
> `arraySplit`/`arrayFold` over whole sessions, which does not decompose into an insert-driven MV),
> while a watermark-driven incremental micro-batch is easy and already proven. That is a definitional
> question about the deliverable, not something we can measure our way out of.

**Status:** open · **Evidence measured:** 2026-08-01, repo state at commit `8af15cb` + local rebuild

---

## The evidence

### 1 · What is continuously updated today, and what is batch

```sql
SELECT name, engine FROM system.tables WHERE database = 'default' AND engine LIKE '%View%';
-- mv_stateless, mv_user_minute  (MaterializedView)
```

| aggregate | updated how | latency to fresh data |
|---|---|---|
| `cc_minute_stateless` (via `mv_stateless`) | **real MV**, insert-driven | seconds |
| `cc_user_minute` (via `mv_user_minute`) | **real MV**, insert-driven | seconds |
| `session_intervals` | `make model` batch | manual |
| `cc_minute_delta` | `make model` batch | manual |
| `cc_hour_agg` | `make model` batch | manual |
| content/title/category views | query-time over `cc_minute_delta` | inherits batch |

### 2 · Why the core is not an MV, and cannot trivially become one

The interval model (`sql/30_build_intervals.sql`) groups **every event of a session** and runs
`arraySplit` (gap detection) + `arrayFold` (pause-window complement) over the whole array. An MV sees
only the rows of one insert block: it cannot re-split a run whose gap closed three inserts ago, and a
session's intervals *shrink* when a pause arrives late — the exact case the `build_version` fix
(WALKTHROUGH §5.1) exists for. An insert-driven MV materially cannot express "re-derive this
session"; only a re-derivation pass can.

### 3 · The incremental path is already proven, just not scheduled

- Absorption test: incremental re-derivation equals a clean rebuild **row for row, all 1,578
  minutes** (`evidence/truncation.txt`, after the versioning fix).
- Full rebuild is **~11 s on Cloud** for the 12-day file; the reconcile gate re-verifies 17,028
  minutes after every build.
- What is missing is only the *trigger*: nothing schedules the rebuild; a human runs `make model`.

---

## Exactly what to ask

> "Step 4 of your README says the pipeline should publish continuously updated aggregates. Our
> session-interval model needs whole-session context — a late pause can *shrink* an interval that was
> already published — so it re-derives affected sessions rather than accumulating inserts, and we've
> proven the re-derivation converges: an incremental pass equals a clean rebuild row-for-row.
>
> **The question:** does a **watermark-driven incremental micro-batch** — re-derive sessions touched
> since the last watermark, every N seconds/minutes, correctness gate attached — satisfy 'continuously
> updated aggregates'? Or do you specifically want insert-driven materialized views end to end, even
> where that forces a simpler (and less correct) stateless model for the session tier?
>
> And if micro-batch is acceptable: is there a freshness bound we should design to — seconds, a
> minute, five minutes?"

---

## Why this is worth mentor time

This is the **largest unshipped deliverable** and the answer picks between two very different builds.
Guessing "MV required" costs a redesign of the one part of the model that is already the most
verified; guessing "micro-batch fine" and being wrong forfeits a named scoring criterion. The
statement's own words ("only works at hackathon size") suggest they care about the *property*
(freshness without full rescans) rather than the *mechanism* — but that is our reading, not theirs.

## How the answer changes what we build

| If they say | We change | Cost |
|---|---|---|
| **"micro-batch is fine"** | schedule the existing incremental build (cron/`clickhouse` refreshable task) on a watermark; expose freshness in ClickStack (panel already exists) | small — the pieces are all proven, we wire a trigger |
| **"freshness bound = X"** | pick batch cadence ≤ X/2; measure end-to-end lag under load and put the number in the deck | the above + one measurement |
| **"must be insert-driven MVs"** | keep `mv_stateless`/`mv_user_minute` as the continuous tier, add an MV-fed *approximate* session tier, and present the reconciled batch tier as the exact layer — a two-tier lambda story, documented honestly | new MV + ADR; the interval model itself stays |
| **"refreshable materialized views count"** | convert `make model` steps into `CREATE MATERIALIZED VIEW … REFRESH EVERY n` — same SQL, engine-managed trigger | moderate; needs Cloud version check |
| *no answer received* | ship the scheduled micro-batch (it strictly dominates the status quo) and defend it in the deck with the convergence + gate evidence | the smallest build that closes the gap either way |

## Our current assumption

A scheduled, watermark-driven incremental rebuild with the reconcile gate attached satisfies
"continuously updated" — the property is freshness + no full rescan, not a specific engine feature.
Unscheduled manual `make model` (the status quo) satisfies **nobody's** reading; that much is certain.

## Answer

_unrecorded_
