# Codex 003 — triage: what is already fixed, what is in flight, what is genuinely new

> **Summary:** Codex 003 audits commit `51ef49f` and reaches "valid core, not fully valid system".
> This triages all of its findings against work that has since merged or is running now, so nothing
> is lost and nothing is worked twice. **Two findings it raises were independently found by our own
> agents the same evening** — the inclusive minute end and second-truncation of pause/resume — which
> is corroboration from a different method, not duplication. **Five findings are genuinely new and
> unowned**, led by publish-time read visibility (a reader can observe a concurrency dip mid-publish)
> and unknown events failing open (an unseen event type silently extends activity — a live risk for
> the unseen day). Its §7.1 list of ten things to keep is also load-bearing: an external reviewer
> confirming the core design is worth as much as its criticisms.

**Triaged:** 2026-08-01, against `dev` after fifteen merges. Codex audited `51ef49f`; several items
below were already fixed in commits it did not see.

---

## A · Already merged — Codex audited a commit that predates the fix

| Codex finding | Status |
|---|---|
| §7.1.6 `ReplacingMergeTree(build_version)`, not `interval_end` | Already shipped — Codex lists it as *valid*, correctly |
| §7.1.8 replaceable user/hour buckets, set-union retraction closed | **ADR 0016**, merged today |
| §7.1.5 `Int64` corrective measures | Already shipped; Codex confirms unsigned would silently wrap |
| §7.1.9 deterministic dimension voting instead of `any()` | **ADR 0009**, shipped |

## B · Independently corroborated — our agents found the same thing by a different route

Worth more than either finding alone, because the methods are unrelated.

| Codex finding | Our independent finding |
|---|---|
| §4.1 / §7.2.7 exact minute end is inclusive, not half-open; "518 affected intervals" | [`doubts/05`](../../doubts/05-minute-boundary-membership.md) measured **505 intervals / 493 sessions**, peak 2,917 → 2,916. Codex's 518 was measured against the **then-live** table, which at that moment was serving two model generations (Validation 002) — our 505 is against the repaired build. |
| §7.2.4 milliseconds discarded by `toUnixTimestamp` on `DateTime64(3)` | [`doubts/08`](../../doubts/08-second-truncation-inverts-pause-resume.md) — second-truncation inverts pause/resume order, worth −52 on the peak |
| §7.3.1–4 crash hole, fencing, timestamp identity, `run_id` collisions | Queue **Q8–Q11**, brief written before this audit landed; branch `docs/publisher-state-machine-safety` running now |
| §10.1 100× interval derivation hit `Code: 241` under default memory | `chore/adr-0016-scale-remeasure` running; this is now an explicit acceptance item |

Codex §7.2.6 also says tail and gap "materially move the answer" — our adversarial audit **quantified
exactly that**: [`doubts/07`](../../doubts/07-tail-credit-at-explicit-stops.md), −141 peak / −7.1% of
hours. And it did not find the largest fork we did: minute membership as instant-sampling,
[`doubts/09`](../../doubts/09-minute-membership-instant-reading.md), **−410 / −14.1%**.

## C · In flight now — owned, not yet merged

| Codex finding | Owner |
|---|---|
| §10.2 projection: re-benchmark `_part_offset` lightweight projections on Cloud 26.2 rather than assuming the old +91% storage multiplier | `docs/query-performance-audit` (**new input — see below**) |
| §13.4 scale gates: per-phase memory, spill, part counts at 1×/10×/100× | `chore/adr-0016-scale-remeasure` |
| §7.3.7 dedup token assumptions differ by engine | partially `fix/hour-rollup-id-collision` |

**New input for the query-performance agent:** Codex flags that ClickHouse now supports
`_part_offset`-based lightweight projections, which may make the shelved `proj_by_session` viable
without the +91% storage that got it shelved. That agent's brief predates this audit and told it to
decide on the old measurement. **Re-check this before accepting its conclusion.**

## D · Genuinely new and unowned — these are the ones that matter

1. **§7.3.5 · Readers observe intermediate publish phases.** Between negating old deltas and emitting
   new ones, minute concurrency can temporarily **drop**; hour and user tiers update later still. A
   dashboard read mid-publish returns a wrong number that no gate would catch, because the gate runs
   between publishes. Minimum fix: both corrections in one insert block. **Not covered by Q8–Q11**,
   which is about crash and concurrency safety, not read visibility.
2. **§7.3.9 · No atomic cross-tier generation.** Minute, hour and user queries can observe different
   publication points. Related to 1, and the reason a `generation_id` is worth considering.
3. **§7.2.9 · Unknown events fail open.** An event value we have never seen silently **extends**
   activity instead of being surfaced. This is a live risk for the **unseen day** specifically — a new
   `event_type` would inflate our answer with no warning. Cheap defence: allow-list the event values
   that grant liveness and alert on anything else.
4. **§7.2.1 / §7.2.3 · Liveness is granted too broadly, and `VideoSessionEnd` is not terminal.**
   `VideoError`, seeks, resizes and telemetry bursts all bridge gaps and earn tail credit; a run can
   receive tail credit *after* an explicit end. Both are semantic questions, but the **exposure is
   measurable today** without changing the model.
5. **§10.3 · Skew and hotspots are untested.** One session with millions of events; a live event where
   most sessions start in one minute; one pathological session dominating a batch. Our scale ladder
   grows uniformly, which is the easy case.

## E · Where we should push back, or at least scope

- **§7.3.6 "remove interval DELETEs".** The advice is sound in general and cites ClickHouse's
  avoid-mutations guidance. But our measured cost is **1.4 s per run** and it is already listed as a
  follow-on in `TODOS.md`. Worth doing; not worth destabilising a passing pipeline for before the
  deadline. Record the decision rather than silently not doing it.
- **§14 "label recent results provisional until an event-time watermark makes them final."** We serve
  a **static file**, not a stream. The watermark distinction is real and belongs in the design
  narrative, but calling our current results provisional would misdescribe what we run. `sonyliv
  observe` already emits `sealed_lag_s` and the hour-tier completeness flag.
- **§12 mentor questions.** Seventeen, overlapping our nine dossiers and `docs/MENTOR_QUESTIONS.md`.
  Do not send both lists — merge them, keep the ones carrying **measured** cost, and lead with
  [`doubts/09`](../../doubts/09-minute-membership-instant-reading.md) (−14.1%) and
  [`doubts/02`](../../doubts/02-resume-semantics.md) (9.7%). A mentor answering two questions well
  beats seventeen answered thinly.

## F · What Codex confirms, which is worth as much as what it criticises

§7.1 lists ten design choices as valid and to be retained: normalised intervals over session spans,
signed minute deltas over per-minute rows, hour clipping, correction-by-diff algebra, `Int64`
corrections, `ReplacingMergeTree(build_version)`, the dirty-session MV used to *index* arrivals
rather than pretend to know cross-block state, replaceable user/hour buckets, deterministic dimension
voting, and the query-time content dictionary.

Its §6 option matrix independently reaches our architecture — "dirty-session finalizer plus
correction-by-diff: **keep and harden**" — and explicitly **rejects** direct incremental-MV
sessionization, which is the obvious-looking design we declined in ADR 0004/0005. An external
reviewer arriving at our design from first principles is a defensible answer to a design-quality
judge, and it belongs in `SUBMISSION.md` §4.
