# WALKTHROUGH — where this project actually stands

> **Summary:** Click-a-thon India 2026 · SonyLIV **foreground-only concurrency**. Built end to end on
> ClickHouse Cloud: session, user and content concurrency off an hour-clipped delta serving layer,
> rolling/tumbling windows, ClickStack charting and self-observing, and four-tier incremental
> publication proven in scratch. The official 7-million-row unseen release adds dynamic dimensions
> and spans 102 output dates; the portal closes automatically at **12:00 PM IST on 2026-08-02**.
> Current closure status and blockers are in Codex Validation 009.
> The graded database remains batch-built: the installed publisher has never committed a run there.
> The original-data peak is **2,917 @ 2026-07-26 10:56**; naive
> session-span says 3,708. The gate compares **every minute in the data — 17,028, idle ones included —
> 0 mismatched**, negative-tested. Rebuild `make model`; prove it `make reconcile`.

**Last verified:** 2026-08-01 · commits through `0b0ec83` (tier coherence restored on the graded
database; headline tiers re-read live the same day: 30,323 intervals · 28,073 deltas · minute peak
2,917 = hour peak 2,917 · user peak 2,844) · ClickHouse Cloud 26.2.1.525

Full session record, including every bug found and every claim corrected: [`docs/SESSION-2026-08-01.md`](docs/SESSION-2026-08-01.md).

---

## 1. The problem, honestly stated

Count viewers **actively watching** each minute — excluding backgrounded, paused and
heartbeat-missing time — from session start/end plus player telemetry. It must serve dashboard-grade
queries from a **serving layer**, not by rescanning session history, and must absorb still-open
sessions and late arrivals. Judges spot-check against raw events; the released unseen data requires
peak/average results at minute, hour and day grain with filters, latency and pipeline evidence.

Full statement: [`docs/upstream/PROBLEM_STATEMENT.md`](docs/upstream/PROBLEM_STATEMENT.md).

**The headline result:** naive session-span overlap counts **2,976.9 hours** of watch time. The
foreground-only model counts **1,978.1 hours** — **33.6% of apparent watch time is backgrounded or
paused**. At the peak minute: 3,708 naive vs **2,917** actual, a 21.3% over-count eliminated.

> Re-baselined 2026-08-01 after [ADR 0009](docs/adr/0009-same-second-resume-and-deterministic-attribution.md)
> fixed a same-second tie in the pause rule. Previously 2,887 / 1,949.3 h / 34.5% / 22.1%.
> Source of truth: `evidence/reconcile.txt`.

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
| `12_publish.sql` | `session_dirty` + publisher run/batch state | incremental publication, ADR 0013 — maintains intervals+deltas **only** |
| `15_normalise.sql` | `norm_*` UDFs, normalised + drift views | query-time normalisation, ADR 0011 |
| `20_views.sql` | all serving views | a chart tool cannot read an `AggregateFunction` |
| `30_build_intervals.sql` | **the model** — active intervals | gaps + explicit pause exclusion |
| `40_deltas.sql` | `cc_minute_delta` | hour-clipped, ADR 0003 |
| `45_user_concurrency.sql` | `cc_user_minute` + user views | replace-not-union buckets (ADR 0016); its INSERT is the canonical re-derivation the publisher templates — platform/country/content_id only |
| `50_hour_agg.sql` | `cc_hour_agg` | peak + integral, 8-level cube — platform/country/content_id only |
| `60_projection.sql` | `ev_raw` projection | **measured not worth shipping** — see §5 |
| `70_truncation_test.sql` | isolated absorption test | runs in `sonyliv_trunc`, never production |
| `80_content.sql` | `dict_content` + content views | title/video_type/category at query time |
| `85_windows.sql` | rolling/tumbling/range window views | platform/country/content_id only |
| `90_reconcile.sql` | **the gate** | truth from `ev_raw` only |

### Quickstart

```bash
direnv allow                       # pinned Go toolchain + .env
tools/fetch_data.sh                # CSVs (sha256-pinned) AND the three spec docs
tools/load.sh                      # or TARGET=cloud tools/load.sh
make model                         # intervals -> deltas -> hour agg -> views -> normalise (5 stages)
make reconcile                     # THE GATE — exits 1 on any mismatch
make clickstack-cloud              # provision HyperDX: 24 sources, SIX dashboards, saved searches
```

---

## 3. The model in three tiers

```
ev_raw  905,558 events · 10,866 sessions · 2026-07-14 15:43 -> 2026-07-26 11:31 UTC
  │
  ├─▶ session_intervals  30,323 rows   ACTIVE ranges per session
  │      gaps > 150s close an interval        (backgrounding — heartbeats stop, 0.047/min)
  │      MINUS explicit pause/resume windows  (pause — heartbeats SURVIVE, 0.756/min)
  │
  ├─▶ cc_minute_delta  28,073 rows     +1 open / -1 close, HOUR-CLIPPED
  │      concurrency(M) = running sum WITHIN M's hour  <- partition by hour or you get
  │      each hour is absolute -> no scan from t=0        plausible wrong numbers
  │
  ├─▶ cc_hour_agg  26,254 rows         peak + integral per hour, 8-level cube
  │      peak is NOT summable across dimensions; it IS maxable over time
  │
  ├─▶ cc_user_minute                   USER concurrency — uniqExact state, NOT deltas
  │      a user can hold several concurrent sessions (72 do, at the peak),
  │      so summing deltas by user_id would double count exactly those
  │      buckets are REPLACED per re-derivation, never set-unioned (ADR 0016),
  │      so a correction can retract a user; the old MV could only ever add
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
| **The gate passes** — truth from `ev_raw` = serving layer | `evidence/reconcile.txt` · **17,028 minutes**, 0 mismatched, `max_abs_diff` 0 |
| Gate actually fails when it should | inject one bad delta row → exit 1; rebuild → exit 0 |
| Delta layer = independent interval expansion | **3,732** minutes, **0** mismatches *(re-run 2026-08-01)* |
| Hour tier = minute tier | 98 hours, **0** mismatches; day peak 2,917 |
| Hour-clipping is correct | interval `20:59:48→22:04:49` emits `+1@20:59`, `+1@21:00`, `+1@22:00`, `-1@22:05`, no close in hours 20/21 |
| Serving is cheaper than expansion | 299 KB / 23 ms vs 2.55 MB / 56 ms — **8.5×** |
| Charts render real data | HyperDX `clickstack_timeseries`, peak day in 1 h buckets: 3 → **2,917** → 2,873; **14 ms**, 28,074 rows *(re-taken 2026-08-01)* |
| Load is exact | `ev_raw` 905,558 = source rows; `content_dim` 33,464 |
| From-scratch rebuild is deterministic | isolated DB reproduces production exactly |
| User concurrency correct | peak **2,844** vs session **2,917**; `uniqExactMerge` 9,531 = 9,531 distinct users *(re-measured 2026-08-01, direct from `session_intervals`; the drift-up-on-rebuild defect in `cc_user_minute` itself is closed by ADR 0016 — buckets are replaced, not unioned)* |
| Content concurrency correct | hour-peak reconcile, **0** mismatches over 6,764 rows — ⚠️ **no evidence file in the tree, and not re-run since**. The recorded run predates ADR 0009 (model change) and ADR 0010 (content views rewritten). Treat as *believed*, not verified, until `evidence/` carries it |
| Rolling/tumbling windows correct | vs brute-force self-join, **0** mismatches at 5/15/60 min — ⚠️ **no evidence file, no tool runs this comparison**, and the one recorded run (`docs/EXPLAINER.md` at `4a89399`) predates ADR 0009 and ADR 0014, which rewrote `sql/85_windows.sql`. Treat as *believed*, not verified |
| Duplicates are inert **at total/peak grain** | full derivation run raw vs deduped: identical totals, **0** of 3,725 minutes differ *(measured at `4a89399`, pre-ADR-0009)*. ⚠️ **Not inert at filter grain** on the current 7-dimension model — a 2026-08-01 re-measure moved 6 interval dimension attributions and the `hin`/`non`/`unk` audio curves on 18/15/26 minutes, UNK audio peak 183 → 184 (`docs/WORKTREE_QUEUE.md` Q5; measured in `evidence/dedup.txt` and [`doubts/06`](doubts/06-dedup-at-filter-grain.md)) |
| Absorption converges (after the fix) | incremental = clean rebuild, row for row, all 1,578 minutes *(pre-ADR-0009, not re-run)* |

---

## 5. What is NOT done

### Two defects — found by test, both now FIXED

1. **Incremental absorption did not converge** — overcounted the peak minute by 37 (2,924 vs 2,887,
   both figures as measured at `388a845`, before ADR 0009 moved the peak to 2,917).
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
| Dedup of repeated events | README step 3 | **proven unnecessary at total/peak grain; NOT at filter grain** — see below |
| **"Publish continuously updated aggregates"** | README step 4 | **DONE for all four tiers** — `sql/12_publish.sql` + `tools/publish.sh`, [ADR 0013](docs/adr/0013-continuous-publication-by-incremental-finalizer.md) + [ADR 0016](docs/adr/0016-publisher-owns-the-user-and-hour-tiers.md). ADR 0013 maintained `session_intervals` + `cc_minute_delta` only; ADR 0016 added the `hours` and `users` phases, so all four tiers converge to a from-scratch rebuild — 0 differing cells across bootstrap, growth, shrink, dimension change, a 46-minute straggler and 200 forced republications (`evidence/publish.txt`). ⚠️ Installed on `sonyliv` but has **never committed a run** there (cursor at epoch) — every live number still comes from a batch rebuild |
| All 10 filter dimensions | dataset_details ("should work even if dimensions increase") | **PARTIAL, non-uniform** — all 7 raw dims carried in `cc_minute_delta` (rows hard-bounded regardless of dimension count, ADR 0008) and in per-dimension dashboard views; 3 content dims via `dict_content` at query time. But hour/day, user, window and stateless paths expose only platform/country/content_id, so e.g. *user concurrency by audio language* or *day peak by app version* needs custom SQL, not a shipped serving shape — see scope limits below |
| H7 OTLP self-instrumentation | ClickStack "meaningful integration" bar | **done** — `sonyliv observe` |
| Unseen-day dry run + evidence packaging | "no pipeline evidence, no credit" | **done** — `tools/unseen-run.sh`, ~2.5 min for a 1 GB day |
| The gate | correctness is scoring criterion #1 | **FIXED** — 17,028 minutes incl. idle, self-targeting, negative-tested |
| ~~**Re-loading a CSV doubles the data**~~ | — | **FIXED** `6355048` — the loader refuses to double the day; evidence in `evidence/load-guard.txt` |
| ~~`CH_DATABASE` env var silently ignored~~ | — | **FIXED** `6355048` — explicit precedence, the environment now wins over `.env` |

**On dedup:** the 4,210 duplicate rows are provably inert **for totals and the headline peak** — the
full derivation run raw vs deduplicated gives identical intervals and 0 of 3,725 minutes differ
(measured at `4a89399`), because the model reads a session's events as a set of instants. The caveat
predicted here has since **come due**: `subtitle_language` *is* now a carried dimension (all 7 raw
dims since ADR 0008), exactly one duplicate group conflicts on it (`UNK` vs `OFF`), and a 2026-08-01
re-measure at the current grain found dedup is **not inert for filtered answers** — 6 interval
dimension attributions change and the `hin`/`non`/`unk` audio curves move on 18/15/26 minutes (UNK
audio peak 183 → 184). Totals and the 2,917 peak are unaffected. The filter-grain policy is an open
decision: `docs/WORKTREE_QUEUE.md` Q5 — measured in `evidence/dedup.txt` and `doubts/06`.

### Scope limits found by the cross-model audits

Verified against the repo and the live database ([docs/codex-validation/002.md](docs/codex-validation/002.md)
supersedes [001](docs/codex-validation/001.md) where they differ). None of these break the headline
numbers; all of them bound what "supported" may honestly mean:

- **`session_start_epoch` is stored, never modeled.** The derivation takes run starts from the
  min/gap-split event timestamps. Harmless on the delivered file (the column matches
  `VideoSessionStart` exactly, 0 mismatches); not a validated invariant for an unseen file.
- **Most event types have no explicit state semantics.** Only exact lowercase `pause`/`resume` and
  `VideoSessionEnd` (for `is_open`) are interpreted; `VideoSessionStart`, `VideoPlay`,
  `AppBackgrounded`, `AppForegrounded` and `VideoError` act only as generic timestamps in the gap
  arithmetic. An observed `AppBackgrounded` does not itself close active state and can earn tail grace.
- **Dimensions collapse to one dominant value per interval** (deterministic tie-break). A viewer who
  changes audio, subtitle, app, platform, user or content mid-interval is not split at the change
  point — a defensible policy, but a policy, not a fact from the data dictionary.
- **Serving paths expose different dimension subsets.** `cc_minute_delta` and `v_session_minutes`
  carry all 7 raw dims; `cc_hour_agg`, `cc_user_minute`, the window views and `cc_minute_stateless`
  carry platform/country/content_id only; content views collapse raw dims. Anything outside a
  shipped shape needs custom SQL over the delta table or the session-minute expansion.
- **The inclusive minute-boundary rule is self-confirming.** Both the model and `90_reconcile.sql`
  count an interval ending exactly on a minute boundary in that minute, so a green gate cannot decide
  between inclusive and half-open (moves 91 minutes, peak 2,917 → 2,916 under the alternative).
  Definition question for a mentor — `docs/WORKTREE_QUEUE.md` Q3.

### Decisions only a human can make

- **Unclosed-pause rule** — 23% of pauses never resume. Conservative (shipped) 1,949.3 h vs permissive
  2,048.6 h: **+99.3 h, 5.09%**. Unknowable from the file. ⚠️ **Both arms were measured at `cf80acc`,
  before the ADR 0009 tie fix.** The conservative arm is now 1,978.1 h; the permissive arm has not
  been re-run, so the spread is stale and is deliberately *not* rescaled here — pairing a new
  conservative number with an old permissive one would invent a delta across two derivations.
- **Local container schema drift** — local `cc_minute_stateless` is `uniq`, Cloud is `uniqExact`.
  Fixing needs `docker compose down -v`, which destroys the local volume.
- **Submission operator** — must assemble the official team folder and open the mandatory PR; the
  published rules do not make this Captain-only.

### Measured and rejected

The `ev_raw` **projection** by `video_session_id` gives 27.7× on single-session lookups with no
dashboard regression — but the actual straggler path uses `IN (subquery)`, which full-scans anyway, so
the real gain is **1.00× for +94% storage**. Kept in the tree, documented, **not in the build path**.

> **Re-measured 2026-08-01 on the finalizer's real query shape, and the second half of that does not
> hold.** `IN (subquery)` does *not* full-scan on 26.2, and with the finalizer's event-time window the
> projection takes a one-session read from **104,640 rows (11.6% of `ev_raw`) to 8,193 (0.9%)** — a
> 12.8× reduction, for +91% storage (3.73 → 7.16 MiB). Still **not shipped**: the finalizer meets its
> target without it and the storage trade is an operator call. Numbers in `evidence/publish.txt`
> PHASE 8 and [ADR 0013](docs/adr/0013-continuous-publication-by-incremental-finalizer.md).

---

## 6. Where the numbers come from

Never hand-computed. `evidence/reconcile.txt` and `evidence/truncation.txt` are regenerated by
`tools/reconcile.sh` and `tools/truncation-test.sh` and committed. The gate exits non-zero on
mismatch, and has been negative-tested to prove it can fail.

If a number in this document disagrees with `evidence/`, **`evidence/` is right and this file is
stale** — fix it.
