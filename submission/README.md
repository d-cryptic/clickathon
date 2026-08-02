# SonyLIV — foreground-only concurrency at streaming scale

> **Summary:** Counts how many viewers are *actively watching* each minute — excluding backgrounded,
> paused and heartbeat-missing time — from session start/end plus 1-minute heartbeats. ClickHouse
> Cloud is the datastore; ClickStack is the OSS integration. On the official unseen file
> (7,000,000 events) the pipeline reconciled **3,201,716 minutes against raw events with zero
> mismatches**. This folder is the self-contained submission package; the engineering repository it
> is cut from carries the full history, ADRs and test suites.

**⚠ THIS FOLDER IS NOT YET COMPLETE.** Items marked **[HUMAN]** below cannot be produced by the
pipeline and must be filled in before the PR is opened. They are listed first, deliberately, so that
nobody reads past them.

---

## Before this is submittable

| | Item | Status |
|---|---|---|
| **[HUMAN]** | Rename this folder to the team name | `submission/` → `<Team Name>/` |
| **[HUMAN]** | Hosted demo URL — must work live, must show the curve, filters must move it | not filled in |
| **[HUMAN]** | 2–3 minute video URL — must walk through real ClickStack dashboards | not filled in |
| **[HUMAN]** | Pitch-deck PDF — `deck/checkpoint1/deck.pdf` exists; confirm it is the final one | needs confirmation |
| **[HUMAN]** | Real ClickStack screenshots embedded here | not embedded |
| **[HUMAN]** | Open the PR titled `[Submission] <Team Name>` | not opened |
| **[HUMAN]** | Secret-scan the full history before publishing — see the note at the bottom | not re-run today |

A static screenshot is **explicitly insufficient** for the demo requirement. The demo and the video
must both show ClickStack working live.

---

## The problem, and why the obvious answer is wrong

Count viewers **actively watching** at each minute. The naive reading — a session is "on" from its
first event to its last — overcounts, because a session that is backgrounded or paused is still a
session. Measured on the sample data, that naive span-based count runs materially high against the
foreground-only truth.

Two signals are needed, not one, and this is the core modelling insight:

- **Heartbeat gaps catch backgrounding.** Heartbeats effectively stop while an app is backgrounded
  (0.047/min, against 4.72/min while active).
- **Explicit pause/resume is required for pausing**, because heartbeats *survive* a pause
  (0.756/min). Gaps alone therefore cannot find paused time — it has to be excluded explicitly.

A model built on gaps alone silently counts every paused viewer as watching. Full reasoning:
[`docs/EXPLAINER.md`](../docs/EXPLAINER.md) and [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## Results on the official unseen file

| | |
|---|---|
| Events | 7,000,000 |
| Landing | lossless — `ev_landing` 7,000,000 = `ev_raw` 7,000,000 + 0 cast rejects |
| Semantically quarantined | 3 (timestamps out of range) |
| Output dates | 102, built as Cloud-legal chunks of 64 + 38 |
| Reconciliation | **3,201,716 minutes compared · 0 mismatched · max_abs_diff 0** |
| Peak concurrency | 23,324 |

Evidence: [`evidence/unseen/official-20260802-codex-validation.txt`](../evidence/unseen/official-20260802-codex-validation.txt).

The full result matrix — peak and average at minute, hour and day grains, dimension-filtered, with
query IDs and latencies — is in [`evidence/submission/`](../evidence/submission/). Every number there
comes from a query that was run, with a `query_id` joinable to `system.query_log`. Nothing in this
submission is hand-computed.

**Two properties of these numbers that are easy to get wrong, and that we state explicitly rather
than let a reader assume:** peak concurrency is **not summable across dimensions** — per-platform
peaks do not add to the total peak, because the peaks occur at different minutes — and average
concurrency is **time-weighted**, not a mean of per-minute values.

## Architecture

Full document: [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md). In brief:

1. **Land losslessly.** All-String, header-aware landing so a malformed row costs a row, not the
   file, and unknown columns survive rather than being dropped.
2. **Derive active intervals** per session from start/end, heartbeat cadence and explicit
   pause/resume — the foreground-only step.
3. **Emit hour-clipped signed minute deltas**: `+1` at open, `−1` at close, clipped to every hour the
   interval touches, so each hour's running sum is absolute rather than dependent on all prior
   history.
4. **Serve** minute / hour / day grains and a separate exact-set user tier (`uniqExact`, not `uniq` —
   an HLL sketch carries 1–2% error against an exact key, which is not acceptable for a headline
   number).

The gate that makes the numbers trustworthy is [`tools/reconcile.sh`](../tools/reconcile.sh): it
recomputes concurrency **from raw events only**, using a different implementation of the same spec
(window functions rather than array splitting), so an error in one shows up instead of cancelling
out. It never reads the serving tables. This matters more under the current rules than it did
before: judges now spot-check results directly against raw events rather than against a private
answer key, which is exactly what this gate already does to itself.

## Filters, and the columns behind them

Required mapping: [`docs/FILTERS.md`](../docs/FILTERS.md) — each filter, the dataset column backing
it, its measured cardinality, and proof that applying it changes the curve.

## ClickStack integration

Wiring, OTel configuration, destination service and tables, and the evidence gap audit:
[`docs/CLICKSTACK_SUBMISSION.md`](../docs/CLICKSTACK_SUBMISSION.md),
[`docs/CLICKSTACK.md`](../docs/CLICKSTACK.md), [`docs/OBSERVABILITY.md`](../docs/OBSERVABILITY.md).
Redacted environment template: [`.env.example`](../.env.example) — no credentials are committed
anywhere in this repository.

## Reproducing this

```bash
tools/fetch_data.sh          # data is NOT in the repo; pulls from the organiser's public repo
make ci                      # build + unit tests
tools/test-all.sh --fast     # the full suite
tools/reconcile.sh           # THE GATE — recomputes from raw and fails on any mismatch
```

## Known limitations, stated rather than hidden

- **Explicit `AppBackgrounded` is not treated as a hard state transition.** The unseen file contains
  4,656 heartbeats occurring while the last explicit state was backgrounded, across 2,422 sessions.
  Under the current model those heartbeats can still generate counted activity. Because judges
  spot-check raw timelines, this is disclosed rather than buried — the measured impact and the
  argument for and against changing it are in the ADR referenced from
  [`REMAINING.md`](../REMAINING.md).
- **Point activity** — a run consisting of a single event yields a zero-length segment that is
  dropped before the tail credit applies, so 182 such runs earn nothing. Keeping them moves the
  sample peak 2,917 → 2,927. This is a semantic choice, measured both ways, awaiting sign-off
  ([ADR 0031](../docs/adr/0031-point-activity-user-attribution-and-the-densify-recipe.md)).
- **Session identity.** 159 session IDs in the unseen file carry more than one start epoch, and 303
  carry more than one user. Grouping by `video_session_id` alone can merge separate incarnations.
- **Tuned constants are declared in one place** ([`policy/model.policy`](../policy/model.policy)) and
  read by every consumer, so an answer can always name the policy it was produced under. They were
  fitted on the sample data; a different corpus could justify different values.

**Secret-scan note for whoever publishes this:** `.env` was never committed and the Cloud password
appears nowhere in tracked files or history, but the Cloud **hostname** does appear in
`evidence/load-guard.txt` and in history. A hostname alone grants no access — decide deliberately
whether to scrub or accept, and rotate credentials after the event regardless.
