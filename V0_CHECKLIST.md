# V0_CHECKLIST — the smallest thing that scores

> **Summary:** Version 0 is the **submittable floor**: a correct, fast, defensible foreground-only
> concurrency system that survives the unseen day, with every known-wrong thing either fixed or
> stated out loud. It is not the full ambition — content-level concurrency, real continuous
> publishing and the 100× story are **v1**, listed at the bottom so nobody mistakes deferral for
> ignorance. Scoring view is [checklist.md](checklist.md); task queue is [TODOS.md](TODOS.md).
> **V0 is done when §A–§F are all green and `make reconcile` exits 0.**

**The v0 bet:** we cannot out-build a missing correctness gate. A submission that is *correct, fast,
evidenced and honest about its gaps* outscores one that is feature-complete and silently wrong on the
unseen day. So v0 buys correctness and evidence first, features last.

The MVP line already marked in [TODOS.md](TODOS.md) — *"sealed tier + stateless baseline is a
complete submission from here"* — is exactly this file's §A.

---

## A. Correctness floor — nothing ships without this

- [x] Active intervals derived from **both** signals: heartbeat gaps (backgrounding) **and** explicit
      pause/resume (heartbeats survive a pause). [ADR 0007](docs/adr/0007-gate-answers-pause-needs-explicit-handling.md)
- [x] `make reconcile` recomputes truth from `ev_raw` alone and exits non-zero on mismatch.
- [x] The gate is negative-tested — it demonstrably *can* fail.
- [x] Session-aware (`cc_minute_delta`) and session-independent (`cc_minute_stateless`) both built.
- [ ] **Duplicate events deduped** — 4,210 rows / 0.46% / 863 sessions. Cheapest correctness win on
      the board and an explicit organiser requirement (README step 3).
- [ ] **Unclosed-pause rule decided and recorded** in ADR 0007. Conservative is the shipped default
      and the safer bet against an exact ground truth; v0 needs the *decision written down*, not
      necessarily a change.

## B. The two proven defects — fix or state

Neither is optional to *address*; both are optional to *fix*. What is not optional is that the
submission does not claim incremental absorption while shipping a model that doesn't converge.

- [ ] `session_intervals` → `ReplacingMergeTree(build_version)`, monotonic `build_version UInt64`.
      Fix is proven to converge on all 1,578 minutes. **Operator approval — schema change to `sonyliv`.**
- [ ] `cc_minute_delta.starts`/`ends` → `SimpleAggregateFunction(sum, Int64)`. Silent `UInt64` wrap
      on a negative corrective row makes any pre-merge read garbage.
- [ ] Re-run `tools/truncation-test.sh`; commit the converged `evidence/truncation.txt`.
- [ ] **If either is deferred:** the +37 / +1.3% overcount is stated plainly in the deck and
      WALKTHROUGH, with the proven fix named. An acknowledged bug costs far less than a discovered one.

## C. Serving + performance evidence

- [x] Dashboards read a serving layer, never a rescan of session history.
- [ ] **`/bench` run over every benchmark shape** — peak *and* average × minute / hour / day ×
      dimension filters. Latency **and bytes read** captured per shape, committed to `evidence/`.
- [ ] At least one filtered shape exercises a **dimension combination** (e.g. platform + country) and
      confirms the peak lands on a different minute than the single-dimension peak. This is the
      likeliest silent-wrong on the benchmark set.

## D. Unseen-day readiness — the highest-leverage v0 item

This is weighted heavily and is pure execution risk: it fails on plumbing, not on modeling.

- [ ] `/unseen` runs end to end on a dataset never seen before, **zero hand edits**, from a clean
      checkout. Rehearse it on a synthetic holdout *before* the real release.
- [ ] Output packages: answers + latencies + **query-log evidence**. *No pipeline evidence, no credit.*
- [ ] Tunables (gap threshold, tail, watermark) live in one place and are not fitted to the tuning file.
- [ ] Wall-clock for the whole run is measured and comfortably inside the final-hours window.

## E. Integration requirement (gating, not scored)

- [x] ClickStack up, HyperDX charting real concurrency off Cloud.
- [ ] **Make it non-superficial** — instrument our own **watermark lag**, not just ingestion lag.
      Nothing of ours emits OTLP yet. One freshness panel driven by our own telemetry converts this
      from "we installed it" to "we observed our pipeline with it", which is what the spec asks for.

## F. Submission hygiene

- [x] LICENSE present. No credentials in git.
- [ ] [WALKTHROUGH.md](WALKTHROUGH.md) refreshed — it currently lists user-level concurrency as
      missing, but `sql/45_user_concurrency.sql` shipped in `a23b116`.
- [ ] `evidence/` regenerated and committed; no number anywhere is hand-computed.
- [ ] Deck: 15 slides mapped to C1–C5, including the **business framing** — 34.5% of apparent watch
      time is backgrounded or paused; 3,708 naive vs 2,887 actual at the peak.
- [ ] Demo rehearsed twice.
- [ ] **Team Captain confirmed and awake before the freeze.**

---

## Explicitly deferred to v1 — say so, don't hide it

Each of these is a real gap. Listing them as *chosen* deferrals, with the reason, is worth more in a
defence than pretending they weren't noticed.

| Deferred | Why it can wait | Why it still matters |
|---|---|---|
| **Content-level concurrency by title** | Needs the `content_dim` enrichment join; no correctness risk to what exists | Named in the organiser's core-aggregations table |
| **Time-window trend** (rolling/fixed) | Derivable from `cc_minute_delta` at query time for the demo | Also a named core aggregation |
| **True continuous publishing** | We batch-rebuild in ~11 s; only `mv_stateless` is a real MV | **The biggest architectural gap** — blueprint step 4, and it is what C3 grades |
| **Filter dimensions: 3 of 10** | The three shipped cover the benchmark shapes | Spec says the design "should work even if dimensions increase" — be ready to explain how |
| Session-aware vs session-independent **numeric** comparison | Both tables exist | The comparison *is* the deliverable, not the two tables |
| 100× scale story | No code needed — a growth law per tier | Judges *will* ask; a whiteboard answer is enough if it is honest |
| Stress matrix (bursty, long-running, concurrent-query) | Costs time, not correctness | Cheap credibility if any of it gets run |

## Not in v0, deliberately

Langfuse and LibreChat layers, the `ev_raw` projection (**measured: 1.00× on the real path for +94%
storage** — rejected on evidence, which is a better story than shipping it), any polished frontend,
auth, or deployment. All out of scope per the spec.
