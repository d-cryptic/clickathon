# V0_CHECKLIST — the smallest thing that scores

> **Summary:** Version 0 is the **submittable floor**: a correct, fast, defensible foreground-only
> concurrency system that survives the unseen day, with every known-wrong thing either fixed or stated
> out loud. Re-evaluated against commits through `50ab153`. **Both proven defects are now fixed**, and
> content, user and window tiers all shipped — v0 is close. What is left is **not modeling work**: it
> is one stale evidence file, one incomplete build path, and the unseen-day rehearsal.
> Scoring view is [checklist.md](checklist.md); status is [WALKTHROUGH.md](WALKTHROUGH.md).
> **V0 is done when §A–§F are green and `make reconcile` exits 0.**

**The v0 bet:** we cannot out-build a missing correctness gate. A submission that is *correct, fast,
evidenced and honest about its gaps* outscores one that is feature-complete and silently wrong on the
unseen day. So v0 buys correctness and evidence first, features last.

**What changed since the last pass** — `388a845` fixed both schema defects and applied them to the
graded database; `34c3f05` landed content enrichment via `COMPLEX_KEY_HASHED` dictionary + title /
category / video_type concurrency; `4a89399` landed nine window views and **proved dedup unnecessary**
rather than bolting it on; `0bc2fda` refreshed WALKTHROUGH. Five of my previous open items closed.
**Two new risks surfaced in their place — §B2 and §D1. Both are single-command fixes and both are
silent-wrong on the unseen day if missed.**

---

## A. Correctness floor — nothing ships without this

- [x] Active intervals from **both** signals: heartbeat gaps (backgrounding) **and** explicit
      pause/resume. [ADR 0007](docs/adr/0007-gate-answers-pause-needs-explicit-handling.md)
- [x] `make reconcile` recomputes truth from `ev_raw` alone; exits non-zero on mismatch.
- [x] The gate is negative-tested — it demonstrably *can* fail.
- [x] Session-aware (`cc_minute_delta`) and session-independent (`cc_minute_stateless`) both built.
- [x] **Dedup — resolved, and better than the fix I asked for.** `4a89399` ran the full derivation
      twice, raw vs `LIMIT 1 BY` the event key, `any()` pinned to `min()` so dedup was the only
      variable: identical 30,769 intervals, **0 of 3,725 minutes differ**; re-run restricted to only
      the 863 duplicate-bearing sessions so it could not wash out — 834 minutes, 0 differing.
      "We proved the step unnecessary" is a stronger defence than "we added the step."
      Evidence: [`evidence/dedup.txt`](evidence/dedup.txt).
- [x] **Non-summability measured, not asserted** — summing per-platform peaks over the 10:00 hour
      gives 2,945 vs a true 2,887 (+2.0%); per-content peaks give 4,433 vs 2,887 (**+53.6%**). This
      was my biggest silent-wrong worry and it is now a defended number.
- [ ] **Unclosed-pause rule decided and recorded** in ADR 0007. Conservative is the shipped default
      and the safer bet against an exact ground truth; v0 needs the *decision written down*, not
      necessarily a change. **Still the only open modeling question.**

## B. Evidence integrity — the new top risk

### B1. Both defects are fixed ✅

- [x] `session_intervals` → `ReplacingMergeTree(build_version)`. Applied to the graded database,
      gate re-run green, delta layer vs interval expansion 0 mismatches over 3,725 minutes.
- [x] `cc_minute_delta.starts`/`ends` → `Int64`. Counters verified sane post-rebuild
      (20,035 starts / 16,895 ends, max single-row 231 — no wrap).
- [x] `cc_user_minute` survived the source-table recreate — `uniqExactMerge` 9,517 = 9,517 distinct
      users. `uniqExact` state is idempotent under re-insertion, so the MV re-firing cannot double count.

### B2. …but the evidence file still says they aren't 🔴

- [ ] **Re-run `tools/truncation-test.sh` and commit the result.**
      [`evidence/truncation.txt`](evidence/truncation.txt) was last written by `5db36ed`
      — *"finds a real convergence bug (not yet fixed)"* — and `388a845` did not regenerate it. Its
      RESULT table still reads `2924 | 2887 | 37` and its **VERDICT still reads "Incremental
      absorption as the schema stands today does NOT converge."**
      WALKTHROUGH now claims absorption converges; that claim currently rests on the *simulation arm*
      inside the old run, not on a post-fix execution.
      **WALKTHROUGH §6 states the tiebreak itself: "If a number in this document disagrees with
      `evidence/`, `evidence/` is right."** By our own rule, the committed evidence says the model is
      broken. A judge who opens `evidence/` — which we invite them to do — reads a failing verdict on
      the criterion we are weakest on. This is the cheapest high-stakes fix on the board.

## C. Serving + performance evidence

- [x] Dashboards read a serving layer, never a rescan of session history.
- [x] Window views verified against independent brute force — rolling peak *and* integral at
      5/15/60 min vs a self-join, 0 mismatches; tumbling 5/15 min, 0 over 807/306 buckets;
      stored hour tier vs recomputed 60-min window, 0 over 98 hours.
- [ ] **`/bench` run over every benchmark shape** — peak *and* average × minute / hour / day ×
      dimension filters. Latency **and bytes read** per shape, committed to `evidence/`.
      **Now the largest untouched item in v0.** Every tier it would exercise exists; nothing blocks it.
- [ ] Granule-pruning evidence on the shapes that matter (`/ch-evidence`).

## D. Unseen-day readiness — still the highest-leverage item

Weighted heavily, and it fails on plumbing rather than modeling — which is exactly what D1 is.

### D1. `make model` does not rebuild the whole model 🔴

`tools/build-model.sh` runs three steps: `30_build_intervals` → `40_deltas` → `20_views`. Nothing in
`Makefile` or `tools/` references `50_hour_agg.sql`, `80_content.sql` or `85_windows.sql` by name —
I grepped. That is fine for 80 and 85 (dictionary + views, self-current) and fine for `45` (MV on
`session_intervals`, idempotent `uniqExact`). **It is not fine for `50_hour_agg.sql`**, which is a
plain `INSERT INTO cc_hour_agg` with no MV feeding it.

So on the unseen day: `make model` rebuilds intervals and deltas, `make reconcile` passes — **because
the gate checks the minute tier** — and `cc_hour_agg` still holds the *old* day's hours. Hour- and
day-grain peak/average are graded benchmark shapes, and they would be answered from a stale tier
behind a green gate. `ReplacingMergeTree(computed_at)` means re-running is safe and non-doubling; the
only defect is that nothing runs it.

- [ ] Add `50_hour_agg.sql` to `tools/build-model.sh` (and confirm 45/80/85 need no rebuild step, or
      add them for symmetry). One line; removes an entire class of silent-wrong.
- [ ] Then: **one command builds everything**, and `make model && make reconcile` is the whole story.

### D2. The rehearsal

- [ ] `/unseen` runs end to end on a dataset never seen, **zero hand edits**, from a clean checkout.
      Rehearse on a synthetic holdout *before* the real release — this is the only item here whose
      cost is unknown until you try it.
- [ ] Output packages answers + latencies + **query-log evidence**. *No pipeline evidence, no credit.*
- [ ] Tunables (`GAP_S`, `TAIL_S`, watermark `W`) live in one place and are not fitted to the tuning file.
- [ ] Whole-run wall-clock measured and comfortably inside the final-hours window.
- [ ] Dictionary reload is part of the run — `dict_content` must pick up unseen-day titles, and
      `v_content_orphan_check` should be read as a live check, not a one-off number.

## E. Integration requirement (gating, not scored)

- [x] ClickStack up, HyperDX charting real concurrency off Cloud.
- [x] Watermark view exists and its two sign traps were caught in build rather than shipped — the
      sealed tier legitimately **leads** raw by ~2 min (TAIL_S grace), so negative `sealed_lag_s`
      is healthy; and `max(hour)+1h` is not a watermark.
- [ ] **Make it non-superficial** — nothing of ours emits OTLP; ClickStack is still read-only
      charting, which is the "superficial inclusion won't count" bar. One freshness panel fed by our
      own watermark telemetry converts "we installed it" into "we observed our pipeline with it."
      The view already computes the number — only the emit path is missing.

## F. Submission hygiene

- [x] LICENSE present. No credentials in git.
- [x] WALKTHROUGH refreshed after the fix and the three new tiers.
- [ ] **WALKTHROUGH §2's SQL table is stale** — it lists nine files and omits `45_user_concurrency`,
      `80_content` and `85_windows`, the three newest tiers. §3's diagram *does* show them, so the
      file contradicts itself. Small, but §2 is the map a judge follows.
- [ ] `evidence/` fully regenerated — see **B2**, which is the one file that is not.
- [ ] Deck: 15 slides mapped to C1–C5, including the **business framing** (34.5% of apparent watch
      time is backgrounded or paused; 3,708 naive vs 2,887 actual at the peak).
- [ ] Demo rehearsed twice.
- [ ] **Team Captain confirmed and awake before the freeze.**

---

## Deferred to v1 — say so, don't hide it

Four rows left this table since the last pass. What remains:

| Deferred | Why it can wait | Why it still matters |
|---|---|---|
| **True continuous publishing** | We batch-rebuild in ~11 s; `mv_stateless` and `mv_user_minute` are real MVs | **The biggest architectural gap** — blueprint step 4, and it is what C3 grades. Now the *only* unmet README requirement |
| **Filter dimensions: 3 of 10** | The three shipped cover the benchmark shapes | Spec says the design "should work even if dimensions increase" — and see the coupling below |
| Session-aware vs session-independent **numeric** comparison | Both tables exist and both are verified | The comparison *is* the deliverable, not the two tables. Cheap now: one query, one paragraph |
| 100× scale story | No code — a growth law per tier | Judges *will* ask; an honest whiteboard answer suffices |
| Stress matrix (bursty, long-running, concurrent-query) | Costs time, not correctness | Cheap credibility if any of it gets run |

**A coupling worth stating in the defence:** dedup is inert *only while `subtitle_language` is not a
dimension*. Exactly one duplicate group is not a byte-identical replay — it differs on that column,
and `dataset_details` names it as a filter dimension. So "dedup unnecessary" and "3 of 10 dimensions"
are the same decision seen twice: widening dimensions makes the duplicate order-dependent and turns
dedup back on. Say it before a judge finds it. (Same shape as ADR 0007's `GAP_S=150`: its p99 of 49 s
was computed on duplicate-bearing data, so 150 stays conservative — but must be recomputed on
deduplicated input if ever retuned.)

## Not in v0, deliberately

Langfuse and LibreChat layers, the `ev_raw` projection (**measured: 1.00× on the real straggler path
for +94% storage** — rejected on evidence, a better story than shipping it), any polished frontend,
auth, or deployment. All out of scope per the spec.
