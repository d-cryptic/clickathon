# Live intervals — what the serving layer believes while sessions are still open

> **Summary:** 32 as-of-T rebuilds of the real derivation across the whole live event (5-minute grid
> 09:00→11:30 on 2026-07-26, plus the 10:56 peak minute), each diffed minute-by-minute against a
> gate-green final build. Of **542,537 minute-cells, 65 are wrong (0.012%)**. The error reaches back
> **180 s** and never further — every cell at age ≥ 240 s is exact, consistent with the model's own
> revision horizon `GAP_S + TAIL_S = 210 s`. It is almost entirely an **under-count**: 61 of 65 cells,
> worst **−446 viewers (−15.3%)** at the newest minute; the largest over-count anywhere is **+2**.
> At the peak, **3,491 sessions were still open but only 311 (8.9%)** could revise an already-served
> minute. Decision + labelling proposal: [ADR 0029](../../docs/adr/0029-provisional-and-final-buckets-labelled-off-the-watermark.md).
> Narrative: [`docs/LIVE_INTERVALS.md`](../../docs/LIVE_INTERVALS.md).

## Why this exists

The problem statement asks directly: *"How do you handle sessions that are still open, whose active
ranges keep growing as new heartbeats arrive?"* The repo already had an answer for **absorbing**
updates — ADR 0013/0016's finalizer appends `−old + new` — proven to converge in
[`evidence/truncation.txt`](../truncation.txt). What was never characterised is **what an open
session's interval IS while it is still open**, and therefore how wrong the newest minutes are, in
which direction, and for how long. That is what these scripts measure.

## Method

For each cut `T` we re-run the **real** derivation (`sql/30_build_intervals.sql`) over the prefix
`event_timestamp < T`. The only edits are mechanical: drop the `INSERT` header so the body becomes a
`SELECT`, and add the prefix predicate. Every tunable, the pause algebra, the dimension attribution
and the `is_open` rule are the shipped ones. That build is what a live dashboard would have served at
`T`. We then diff it against the completed build over a **dense** minute spine.

Cutting on `event_timestamp` isolates one variable deliberately: this is the error from **sessions
still being in flight**, with ingestion assumed instant. Arrival lateness is a second, independent
axis (measured elsewhere at up to 2,081 s — ADR 0007); ADR 0029 composes the two.

Concurrency is counted by **interval expansion**, not by reading `v_concurrency_minute_delta_total`,
because that view is deliberately sparse — it emits a row only where a session opens or closes
(1,579 minutes against the 3,732 a session actually covers) and a reader carries the running sum
across the gaps. Diffing two sparse curves would score every carried minute as absent. `00-setup.sh`
PHASE 4 proves expansion equals the served delta curve on every minute the delta tier emits.

## Files

| File | What it is |
|---|---|
| `00-setup.sh` / `.txt` | Scratch db `sonyliv_v3live`: schema, a copy of the 13 canonical `ev_raw` columns, the final build, and **the gate** — 17,028 minutes, 0 mismatched, peak 2,917. Plus the expansion-vs-delta cross-check. |
| `10-asof-sweep.sh` / `.txt` | The 32 as-of-T derivations (279,524 intervals) and the per-cut curve against a dense spine (542,537 cells). ~45 s. |
| `20-analyse.sh` / `.txt` | The five answers: provisional window, direction, provisional share, convergence, dashboard-window impact. |

## The numbers that matter

| Measurement | Value |
|---|---|
| Cells wrong, all cuts | **65 of 542,537 (0.012%)** |
| Oldest age ever wrong | **180 s** (every cell at ≥ 240 s exact; model horizon `GAP_S + TAIL_S` = 210 s) |
| Newest minute, mean error | **−14.8%** · worst **−75.2%** (10:30, the ramp onset) · worst absolute **−446** (10:56) |
| One minute back (age 60 s) | mean **−1.7%**, worst **−60** viewers |
| Two–three minutes back | ≤ **1** viewer, either direction |
| Largest over-count anywhere | **+2 viewers** (4 cells of 542,537) |
| Open sessions at the peak cut | **3,491** — of which **311 (8.9%)** revise an already-served minute |
| Share of the newest minute's count from still-open sessions | **92.7%** mean |

## Reproduce

```bash
evidence/live/00-setup.sh      # ~25 s, builds sonyliv_v3live and proves it green
evidence/live/10-asof-sweep.sh # ~45 s, 32 derivations
evidence/live/20-analyse.sh    # the report
tools/ch -c "DROP DATABASE IF EXISTS sonyliv_v3live"   # cleanup
```

`sonyliv` is read with `SELECT` on `ev_raw` only and is never written. Each script greps itself for
writes against the graded database and refuses to run if it finds one.

## A caveat on the baseline

The final build here scores **peak 2,917 @ 2026-07-26 10:56**, which is what the committed SQL
produces today — `sql/30_build_intervals.sql`'s own post-fix comment and the control build in
[`evidence/truncation.txt`](../truncation.txt) both say 2,917. The **2,887** that appears in older
prose predates ADR 0009's inclusive-resume (`>=`) fix, which recovered ~23 h of wrongly-excluded
active time. We build our own baseline rather than reading the graded database because that database
currently fails its own reconcile and serves three tier vintages
([`evidence/query-robustness/README.md`](../query-robustness/README.md) F1).
