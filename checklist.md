# CHECKLIST — what we are scored on, and where we stand

> **Summary:** The judging rubric, compacted from handwritten notes and reconciled against the
> organiser's actual spec in [docs/upstream/](docs/upstream/). This file is the **scoring view**: what
> judges grade, what we must be able to defend, and where each answer already lives. It deliberately
> does **not** re-explain the model — that is [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the
> ADRs. The portal closes automatically at **12:00 PM IST on 2026-08-02**. Task queue is
> [TODOS.md](TODOS.md); honest status is [WALKTHROUGH.md](WALKTHROUGH.md).
> For the minimum shippable cut, see [V0_CHECKLIST.md](V0_CHECKLIST.md).

**Golden rule:** optimize ingestion *and* querying while holding correctness, scalability and
robustness. Every choice — schema, interval representation, aggregation strategy, MVs, computational
model — must be defensible on performance, maintainability and business value, not just algorithmic
correctness. **Judges value *why* as much as *how*.**

---

## 1. The five graded criteria

Straight from [PROBLEM_STATEMENT.md](docs/upstream/PROBLEM_STATEMENT.md#how-you-will-be-evaluated).
Everything in this file exists to serve one of these.

| # | Criterion | What judges actually check | Our state |
|---|---|---|---|
| C1 | **Correctness** | Judges spot-check concurrency against raw events. Foreground-only means foreground-only; overcounting backgrounded time is *the* failure mode. | Gate passes vs accepted raw events — [`evidence/reconcile.txt`](evidence/reconcile.txt) |
| C2 | **Query performance** | Latency at the given volume, **and what the queries read** — not just wall time. | 299 KB / 23 ms vs 2.55 MB / 56 ms (8.5×) |
| C3 | **Update handling** | Open sessions + late heartbeats absorbed **incrementally**, or recomputed? | ✅ converges after the `388a845` schema fixes (`evidence/truncation.txt`, re-run 2026-08-01: all 1,579 minutes, peak 2,917). ⚠️ Incremental path covers `session_intervals`+`cc_minute_delta` only; hour/user tiers batch-rebuild, and the installed publisher has never committed a run on `sonyliv` — see §4/§5 |
| C4 | **Design quality** | Schema/representation choices *and the reasoning*. "A team that can defend its trade-offs beats a team with a lucky benchmark." | ADRs 0001–0014 |
| C5 | **The unseen data** | Peak/average minute/hour/day results with filters, latencies **and pipeline evidence**. *No pipeline evidence, no credit.* | Official 7M local release path green: 64+38 date chunks, 3,201,716 reconciled minutes, 0 mismatches; `evidence/unseen/official-20260802-codex-validation.txt` |

### Hard requirements (not scored — gating)

- [x] **ClickHouse is the primary datastore** — ingestion, modeling, all concurrency computation live
      in `sql/`; the Go binary orchestrates and observes, it computes nothing.
- [x] **Meaningfully integrate** ClickStack, Langfuse **or** LibreChat. *Superficial inclusion won't count.*
      → ClickStack in both directions: six hosted dashboards chart our serving layer, and
      `sonyliv observe` emits our watermark lag / build timing / gate outcome over OTLP
      (docs/OBSERVABILITY.md). ⚠️ Two persisted user-tier sources select the wrong column —
      `docs/WORKTREE_QUEUE.md` Q13.
- [ ] **Package the newly required ClickStack proof.** Commit deployment/integration and OTel
      config, a secrets-redacted `.env.example`, name the destination ClickHouse service/tables,
      put the dashboards/searches actually used in the README, and walk them through live in the
      hosted demo and video. Screenshots alone are explicitly insufficient.
- [ ] **No hand-computed answers.** Every number traceable to a query log or trace. *(Ongoing rule,
      re-checked at submission.)*
- [ ] **No credentials in git.** *(Ongoing rule, re-checked at submission.)*
- [x] LICENSE present (MIT, restored from `fc2c483`).

---

## 2. Correctness (C1)

- [x] **Active-interval definition is precise and defended** — heartbeat gap > 150 s closes an
      interval (backgrounding), **minus** explicit pause/resume windows. Two signals, because
      heartbeats *survive* a pause at 0.756/min — inside any sane gap threshold. [ADR 0007](docs/adr/0007-gate-answers-pause-needs-explicit-handling.md)
- [x] **Truth is recomputed from `ev_raw`**, not asserted against the serving layer. A test that reads
      the model to check the model proves nothing — [docs/TESTS.md](docs/TESTS.md).
- [x] **The gate can fail.** Negative-tested: inject one bad delta row → exit 1.
- [x] Tier agreement: minute ↔ delta expansion (**3,732** min, 0 mismatches, re-run 2026-08-01);
      hour ↔ minute (98 h, 0).
- [ ] **Unclosed-pause rule decided** — 23% of pauses never resume. Conservative 1,949.3 h vs
      permissive 2,048.6 h (**+5.09%**). Unknowable from the file. **Operator/mentor call.**
      ⚠️ Both arms measured at `cf80acc`, **before** the ADR 0009 tie fix. The conservative arm is
      now 1,978.1 h; the permissive arm has not been re-run, so the spread is stale. Not rescaled
      here on purpose — re-measuring needs a rebuild with `UNCLOSED_PAUSE_TO_RUN_END = 0`.
- [x] Session-aware vs session-independent **numerically compared**: 2,894 stateless vs 2,917
      session-aware at the peak minute ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) layer 5).

### Edge cases — each needs a defined, tested behaviour

Empty strings · NULL timestamps · duplicate records (**4,210 rows, 0.46%, 863 sessions — measured
inert for totals/peak, NOT inert at filter grain: 6 attributions and three audio curves move,
`docs/WORKTREE_QUEUE.md` Q5**) · missing session end · missing heartbeat · zero-length and invalid intervals ·
out-of-order events · overlapping sessions for one user. Traps that actually bite are in
[docs/DATA_DICTIONARY.md#traps](docs/DATA_DICTIONARY.md) — `event_timestamp` is epoch **ms**,
backgrounding is universal, bg/fg events are **not guaranteed to pair**.

---

## 3. Query performance (C2)

- [x] Serving layer answers without rescanning session history.
- [x] Sort keys are dimension-first then time, per [docs/CONVENTIONS.md](docs/CONVENTIONS.md) and
      [ADR 0002](docs/adr/0002-order-by-time-bucket-then-platform.md).
- [ ] **`/bench` run on the full benchmark shapes** — peak **and** average concurrency × minute /
      hour / day × dimension filters. Capture latency **and bytes read** for every shape.
- [ ] Granule-pruning evidence per shape (`/ch-evidence`).

> **The dimension trap.** Peak is **not summable across dimensions**: platform alone and
> platform+country peak at *different minutes* in the same range. Peak is never stored pre-combined —
> hour-clipping is what makes it maxable over *time*. This is the single most likely place to be
> silently wrong on a filtered benchmark query.

---

## 4. Update handling (C3) — our weakest criterion

- [x] Open sessions represented (`is_open`), watermark sized from measurement: stragglers arrive up
      to **2,081 s** after `VideoSessionEnd` → W = 2400 s.
- [x] Late-arrival correction-by-diff designed and arithmetically exact — [ADR 0006](docs/adr/0006-late-arrival-correction-by-diff.md).
- [x] Absorption is **actually tested**, not asserted — `tools/truncation-test.sh` cuts the stream at
      the peak and replays 447,081 withheld events.
- [x] **…and after the two §5 schema fixes it converges** — re-run 2026-08-01 on the current model:
      versioned incremental == production truth on **all 1,579 minutes, peak 2,917**
      (`evidence/truncation.txt`; the file deliberately keeps the broken `interval_end` variant to
      prove the test still *detects* the historical +37 divergence).
- [x] **"Publish continuously updated aggregates"** — **all four tiers.** ADR 0013's finalizer
      maintained `session_intervals` + `cc_minute_delta` only; **ADR 0016** added the `hours` and
      `users` phases, so the hour/day cube and the user tier are re-derived for the buckets a batch
      touched. All four converge to a from-scratch rebuild — 0 differing cells across bootstrap,
      growth, shrink, dimension change, a 46-minute straggler and 200 forced republications
      (`evidence/publish.txt`). ⚠️ On `sonyliv` it is installed but has **never committed a run**
      (cursor at epoch), so every live number still comes from a batch rebuild.

---

## 5. Known defects — both FIXED at `388a845` and applied to the graded database

Kept as a record; the gate was re-run green after each.

1. ~~`session_intervals` was `ReplacingMergeTree(interval_end)`~~, which assumes re-derivation only
   ever *extends* an interval. It doesn't — the `TAIL_S=60s` grace can overshoot, so a stale row won
   forever (316 intervals too long, 315 stuck `is_open=1`). **Fixed:** versioned on monotonic
   `build_version`; convergence re-proven 2026-08-01 on all 1,579 minutes (`evidence/truncation.txt`).
2. ~~`cc_minute_delta.starts`/`ends` were `UInt64`~~ and silently wrapped on a negative corrective row
   (`max()` returned 1.8e19). **Fixed:** `SimpleAggregateFunction(sum, Int64)`; counters verified sane
   post-rebuild.

---

## 6. Deliverables from the organiser's blueprint

[README_START_HERE.md](docs/upstream/README_START_HERE.md) — "integration goal: join content and
event streams in real time to produce one or more aggregated tables."

| Deliverable | State |
|---|---|
| Foreground concurrency | ✅ `cc_minute_delta` → `cc_hour_agg` |
| Session-aware **and** session-independent tables | ✅ both; compared at the peak minute: 2,894 stateless vs 2,917 session-aware |
| User-level concurrency (`uniqExact`, **not** deltas — a user holds several sessions) | ✅ `sql/45_user_concurrency.sql` — platform/country/content_id grain only |
| **Content-level concurrency by title** (metadata enrichment) | ✅ `sql/80_content.sql` — `dict_content` + title/type/category views, hour-peak reconciled 0 mismatches. Title is a label, not an asset key: 2,773 titles map to >1 content_id |
| **Time-window trend** — rolling / fixed windows | ✅ `sql/85_windows.sql` — verified against brute-force self-join, 0 mismatches at 5/15/60 min. platform/country/content_id grain only |
| **Dedup of repeated events** | ⚠️ **decided, scoped** — proven inert for totals/peak (`evidence/dedup.txt`); NOT inert at filter grain (Q5 — `evidence/dedup.txt`, `doubts/06`): 6 attributions and the `hin`/`non`/`unk` audio curves move |
| Schemas documented from `dataset_details.md` | ✅ [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) |
| Filter dimensions survive derivation | ⚠️ **7 of 7 raw dims carried in the interval/delta tier** (ADR 0008; bounded rows) + 3 content dims via dictionary — but hour/day, user, window and stateless paths expose only platform/country/content_id, so support is **not uniform** across grains ([codex-validation/002.md](docs/codex-validation/002.md) §8) |

---

## 7. Scale & stress — what "100×" answers require

Judges will ask how the design behaves at 100×. Choices that only work at hackathon size (full
rescans, per-minute explosion of all history) "will be treated as what they are."

Measured at 1×, 10× and 100× — [evidence/scale.txt](evidence/scale.txt), regenerate with
`tools/scale-test.sh`. 100× = 1,086,600 sessions / 89.85M events / peak concurrency 251,668.

- [x] High volume — **1.09M sessions, 89.85M events**; growth law per tier is in the file
      (serving reads are flat at the hour tier, delta rows stay 88.7% of the ADR 0008 ceiling).
- [ ] High update rate — continuous heartbeats, frequent session mutation.
- [ ] Concurrent queries during ingestion.
- [ ] Long-running sessions (hours → days) — does hour-clipping hold?
- [x] Bursty traffic — mass simultaneous start/end. The synthetic stream keeps the real
      **85% of events inside two of 99 hours**, and the gate passes on all 6,799 minutes.
- [ ] Late and out-of-order data.
- [ ] Duplicate events — idempotency demonstrated.
- [ ] Missing events — no heartbeat, no session end.
- [x] **What breaks first, with the number.** The interval derivation's memory —
      4.48 GiB of a 5.56 GiB server at 100×, `Code: 241` at default settings.
      NOT part count (28 of 3,000), NOT merge throughput, NOT dictionary memory
      (17.00 MiB at every scale). Thread cap to 2 → 2.59 GiB and *faster*.

---

## 8. The unseen day (C5)

Released to all teams simultaneously in the final hours. **Build for it, not for the file we tuned on.**

- [ ] `/unseen` runs end to end with **zero** hand edits, on a dataset never seen.
- [ ] Required peak/average minute/hour/day concurrency results + latencies captured.
- [ ] Query-log / trace evidence packaged alongside. *No pipeline evidence, no credit.*
- [ ] Nothing in the model is fitted to the tuning file's constants (gap threshold, tail, watermark
      are declared tunables in one place, and the sensitivity sweep is run).

---

## 9. Defence — the questions to be ready for

One list. Each should be answerable in under a minute, pointing at a doc.

**Model.** What is your interval definition, and why two signals instead of one? How are active
ranges represented — arrays, normalized intervals, minute deltas, hybrid? Why hour-clipping?

**Computation.** How do you compute overlap accurately? Peak vs average — why is peak not stored?
Why is peak not summable across dimensions but maxable over time?

**Updates.** How are open sessions represented and finalized? How are late events absorbed
incrementally rather than by rebuild? What is your watermark, and how did you *measure* it?

**Storage.** Aggregate or raw? Session-aware or session-independent — and what did comparing them
show? Why this ordering key? Why materialized views, and what stays raw?

**Data quality.** Duplicates, NULLs, empty strings, erroneous records — where in the pipeline, and why there?

**Evidence.** Which required concurrency queries, which metrics, what did they read? Show the query log.

**Business.** What decision does this change? Naive counting says 2,976.9 h of watch time; the
foreground-only model says 1,978.1 h — **33.6% of apparent watch time is backgrounded or paused**, and
ad load, capacity and content calls are all made on that number. At the peak minute: 3,708 naive vs
**2,917** actual, a 21.3% over-count removed.

**Trade-offs.** For every alternative you rejected — what did you measure? (Good answer on file: the
`ev_raw` projection gives 27.7× on single-session lookups but **1.00×** on the real straggler path,
for +94% storage. Measured, documented, deliberately not shipped.)

---

## 10. Submission

- [ ] Every unchecked box above is either done or **consciously accepted and stated**.
- [ ] [WALKTHROUGH.md](WALKTHROUGH.md) matches reality; `evidence/` regenerated and committed.
- [ ] Deck: 15 slides mapped to C1–C5.
- [ ] Demo rehearsed twice — replay a live-event day: ingest → curve builds → apply a filter →
      minute-grain answers instantly.
- [ ] Hosted demo link and recorded 2–3 minute video are present in the team README.
- [ ] Self-contained team folder contains source, README, architecture, pitch PDF and ClickStack
      evidence, then is submitted in one PR titled `[Submission] Team Name`.
