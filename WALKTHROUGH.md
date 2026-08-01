# WALKTHROUGH — where this project actually stands

> **Summary:** Click-a-thon India 2026 · SonyLIV **foreground-only concurrency**. Built end to end on
> ClickHouse Cloud: session, user and content concurrency off a hour-clipped delta serving layer,
> all 7 raw dimensions, rolling/tumbling windows, ClickStack both charting and self-observing. Peak
> **2,887 @ 2026-07-26 10:56**; naive session-span would say 3,708. The correctness gate compares
> **every minute in the data — 17,028 of them, idle ones included** — against truth recomputed from
> `ev_raw` alone, derives its own target minutes so it works on any day, and has been negative-tested
> to prove it fails when it should. The remaining gap is architectural: aggregates are
> **batch-rebuilt, not continuously updated**. Rebuild `make model`; prove it `make reconcile`.

**Last verified:** 2026-08-01 · commits through `1dee090` · ClickHouse Cloud 26.2.1.525

Full session record, including every bug found and every claim corrected: [`docs/SESSION-2026-08-01.md`](docs/SESSION-2026-08-01.md).

---

## 1. The problem, honestly stated

Count viewers **actively watching** each minute — excluding backgrounded, paused and
heartbeat-missing time — from session start/end plus player telemetry. It must serve dashboard-grade
queries from a **serving layer**, not by rescanning session history, and must absorb still-open
sessions and late arrivals. Scored against a **private ground truth** plus an **unseen day** released
in the final hours.

Full statement: [`docs/upstream/PROBLEM_STATEMENT.md`](docs/upstream/PROBLEM_STATEMENT.md).

**The headline result:** naive session-span overlap counts **2,976.9 hours** of watch time. The
foreground-only model counts **1,949.3 hours** — **34.5% of apparent watch time is backgrounded or
paused**. At the peak minute: 3,708 naive vs **2,887** actual, a 22.1% over-count eliminated.

---

## 2. How to traverse this repo

Start at [`AGENTS.md`](AGENTS.md) — it is a router, not a manual. Then:

| You want to… | Go to |
|---|---|
| Understand the model and why | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| See the organiser's actual spec | [`docs/upstream/`](docs/upstream/) — **the contract, never edit** |
| Know the data shape and its traps | [`docs/DATA_DICTIONARY.md`](docs/DATA_DICTIONARY.md) |
| Understand a design decision | [`docs/adr/`](docs/adr/) — 0007 is the most consequential |
| Know what is **proven** vs assumed | [`docs/VERIFIED.md`](docs/VERIFIED.md), [`evidence/`](evidence/) |
| Know what is tested | [`docs/TESTS.md`](docs/TESTS.md) |
| Run something | [`tools/README.md`](tools/README.md) |
| Pick up work | [`TODOS.md`](TODOS.md) |
| Ask the organisers | [`docs/MENTOR_QUESTIONS.md`](docs/MENTOR_QUESTIONS.md) |

### The SQL, in execution order

`sql/` is numbered so the sequence *is* the pipeline:

| File | Builds | Notes |
|---|---|---|
| `00_schema.sql` | `ev_raw`, `content_dim` | sort key per ADR 0002 |
| `10_intervals.sql` | `session_intervals`, `cc_minute_delta`, `cc_minute_stateless` | table defs only |
| `20_views.sql` | all serving views | a chart tool cannot read an `AggregateFunction` |
| `30_build_intervals.sql` | **the model** — active intervals | gaps + explicit pause exclusion |
| `40_deltas.sql` | `cc_minute_delta` | hour-clipped, ADR 0003 |
| `50_hour_agg.sql` | `cc_hour_agg` | peak + integral, 8-level cube |
| `60_projection.sql` | `ev_raw` projection | **measured not worth shipping** — see §5 |
| `70_truncation_test.sql` | isolated absorption test | runs in `sonyliv_trunc`, never production |
| `90_reconcile.sql` | **the gate** | truth from `ev_raw` only |

### Quickstart

```bash
direnv allow                       # pinned Go toolchain + .env
tools/fetch_data.sh                # CSVs (sha256-pinned) AND the three spec docs
tools/load.sh                      # or TARGET=cloud tools/load.sh
make model                         # intervals -> deltas -> views -> reconcile   (~11 s on Cloud)
make reconcile                     # THE GATE — exits 1 on any mismatch
make clickstack-cloud              # provision HyperDX sources, dashboard, saved searches
```

---

## 3. The model in three tiers

```
ev_raw  905,558 events · 10,866 sessions · 2026-07-14 15:43 -> 2026-07-26 11:31 UTC
  │
  ├─▶ session_intervals  30,769 rows   ACTIVE ranges per session
  │      gaps > 150s close an interval        (backgrounding — heartbeats stop, 0.047/min)
  │      MINUS explicit pause/resume windows  (pause — heartbeats SURVIVE, 0.756/min)
  │
  ├─▶ cc_minute_delta  24,951 rows     +1 open / -1 close, HOUR-CLIPPED
  │      concurrency(M) = running sum WITHIN M's hour  <- partition by hour or you get
  │      each hour is absolute -> no scan from t=0        plausible wrong numbers
  │
  ├─▶ cc_hour_agg  26,162 rows         peak + integral per hour, 8-level cube
  │      peak is NOT summable across dimensions; it IS maxable over time
  │
  ├─▶ cc_user_minute                   USER concurrency — uniqExact state, NOT deltas
  │      a user can hold several concurrent sessions (72 do, at the peak),
  │      so summing deltas by user_id would double count exactly those
  │
  ├─▶ dict_content + v_concurrency_minute_{title,video_type,category}
  │      COMPLEX_KEY_HASHED — a plain HASHED dictionary cannot dictGet a
  │      NEGATIVE key, and content_dim has one
  │
  ├─▶ v_cc_rolling_* / v_cc_tumbling_* / v_cc_window_range
  │      RANGE frames, not ROWS: the delta layer stores rows only where
  │      concurrency CHANGES, so "5 rows back" is not "5 minutes back"
  │
  └─▶ cc_minute_stateless  91,292 rows session-INDEPENDENT baseline (the comparison deliverable)
```

**Why two signals, not one** — the single most important thing in this repo, measured in
[ADR 0007](docs/adr/0007-gate-answers-pause-needs-explicit-handling.md):

| State | Heartbeat rate | Detectable by gaps? |
|---|---|---|
| Actively watching | 4.72 /min | — |
| **Backgrounded** | **0.047 /min** (100× drop) | **yes** |
| **Paused** | **0.756 /min** (~1 event / 79 s) | **NO** — inside any sane threshold |

A gap-only model counts paused time as watching. That is why pause is excluded *explicitly*.

Also disproven: `VideoHeartbeat` is **not** a 60-second beat. It is bursty telemetry —
inter-arrival p50 **0 s**, p90 40 s, p99 49 s. The organiser's own `dataset_details.md` says "passed
every 1 minute"; the shipped data disagrees. **Open mentor question.**

---

## 4. What is verified

Everything here was run, not reasoned about.

| Claim | Evidence |
|---|---|
| **The gate passes** — truth from `ev_raw` = serving layer | `evidence/reconcile.txt` · 5 minutes, all delta 0 |
| Gate actually fails when it should | inject one bad delta row → exit 1; rebuild → exit 0 |
| Delta layer = independent interval expansion | 3,725 minutes, **0** mismatches |
| Hour tier = minute tier | 98 hours, **0** mismatches; day peak 2,887 |
| Hour-clipping is correct | interval `20:59:48→22:04:49` emits `+1@20:59`, `+1@21:00`, `+1@22:00`, `-1@22:05`, no close in hours 20/21 |
| Serving is cheaper than expansion | 299 KB / 23 ms vs 2.55 MB / 56 ms — **8.5×** |
| Charts render real data | HyperDX `clickstack_timeseries`: 61 → **2,887** → 7, 28 ms |
| Load is exact | `ev_raw` 905,558 = source rows; `content_dim` 33,464 |
| From-scratch rebuild is deterministic | isolated DB reproduces production exactly |
| User concurrency correct | peak 2,815 vs session 2,887; `uniqExactMerge` 9,517 = 9,517 distinct users |
| Content concurrency correct | hour-peak reconcile, **0** mismatches over 6,764 rows |
| Rolling/tumbling windows correct | vs brute-force self-join, **0** mismatches at 5/15/60 min |
| Duplicates are inert | full derivation run raw vs deduped: identical intervals, **0** of 3,725 minutes differ |
| Absorption converges (after the fix) | incremental = clean rebuild, row for row, all 1,578 minutes |

---

## 5. What is NOT done

### Two defects — found by test, both now FIXED

1. **Incremental absorption did not converge** — overcounted the peak minute by 37 (2,924 vs 2,887).
   `session_intervals` was `ReplacingMergeTree(interval_end)`, which assumes re-derivation only ever
   *extends* an interval. It doesn't: 316 intervals ran up to 60 s too long, 315 stuck at
   `is_open=1`. Now versioned on a monotonic `build_version` — incremental equals a clean rebuild on
   all 1,578 minutes.
2. **`cc_minute_delta.starts/ends` were `UInt64`** and wrapped when a corrective row was negated
   (`max()` returned 1.8e19, `starts` inflated 22%). Now `Int64`.

Both applied to the graded database, gate re-run green.

### Required deliverables still missing

Found late — `tools/fetch_data.sh` originally pulled only the CSVs, so
`README_START_HERE.md` and `dataset_details.md` went unread. The fetcher now syncs all three.

| Item | Source | State |
|---|---|---|
| Content-metadata enrichment + concurrency by title | README step 2 | **done** |
| User-level concurrency | dataset_details | **done** |
| Time-window trend | core aggregation | **done** |
| Dedup of repeated events | README step 3 | **proven unnecessary** — see below |
| **"Publish continuously updated aggregates"** | README step 4 | **STILL MISSING — the biggest gap.** We batch-rebuild via `make model`; only `mv_stateless` and `mv_user_minute` are real MVs |
| All 10 filter dimensions | dataset_details ("should work even if dimensions increase") | **done** — 7 raw carried, 3 via `dict_content`. Row count is hard-bounded at 36,930 regardless of dimension count |
| H7 OTLP self-instrumentation | ClickStack "meaningful integration" bar | **done** — `sonyliv observe` |
| Unseen-day dry run + evidence packaging | "no pipeline evidence, no credit" | **done** — `tools/unseen-run.sh`, ~2.5 min for a 1 GB day |
| The gate | correctness is scoring criterion #1 | **FIXED** — 17,028 minutes incl. idle, self-targeting, negative-tested |
| **Re-loading a CSV doubles the data** | — | **BROKEN** — the claimed idempotency setting is for non-replicated MergeTree; Cloud is SharedMergeTree |
| `CH_DATABASE` env var silently ignored | — | **BROKEN** — a retarget appears to work and writes to production |

**On dedup:** the 4,210 duplicate rows are *provably inert* — the full derivation run raw vs
deduplicated gives identical intervals and 0 of 3,725 minutes differ, because the model reads a
session's events as a set of instants. One caveat: exactly one duplicate group is not a byte-identical
replay — it differs in `subtitle_language` (`UNK` vs `OFF`). That is harmless only while
`subtitle_language` is not a dimension, and `dataset_details` names it as one.

### Decisions only a human can make

- **Unclosed-pause rule** — 23% of pauses never resume. Conservative (shipped) 1,949.3 h vs permissive
  2,048.6 h: **+99.3 h, 5.09%**. Unknowable from the file.
- **Local container schema drift** — local `cc_minute_stateless` is `uniq`, Cloud is `uniqExact`.
  Fixing needs `docker compose down -v`, which destroys the local volume.
- **Team Captain** — only they can submit.

### Measured and rejected

The `ev_raw` **projection** by `video_session_id` gives 27.7× on single-session lookups with no
dashboard regression — but the actual straggler path uses `IN (subquery)`, which full-scans anyway, so
the real gain is **1.00× for +94% storage**. Kept in the tree, documented, **not in the build path**.

---

## 6. Where the numbers come from

Never hand-computed. `evidence/reconcile.txt` and `evidence/truncation.txt` are regenerated by
`tools/reconcile.sh` and `tools/truncation-test.sh` and committed. The gate exits non-zero on
mismatch, and has been negative-tested to prove it can fail.

If a number in this document disagrees with `evidence/`, **`evidence/` is right and this file is
stale** — fix it.
