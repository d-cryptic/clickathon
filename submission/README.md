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

Full mapping with measured cardinalities, filtered peaks and query IDs:
[`docs/FILTERS.md`](../docs/FILTERS.md). Unfiltered baseline: **peak 23,324 @ 2026-07-31 11:17**.

| Filter | Column · table | Filtered peak | Moves the curve? |
|---|---|---:|---|
| Platform | `platform` · ev_raw | 7,159 | −69.3% |
| **Country** | `country` · ev_raw | 23,324 | **no — see below** |
| Title | `title` · content_dim | 9,143 | −60.8% |
| Content ID | `content_id` · ev_raw | 9,143 | −60.8% |
| App version | `app_version` · ev_raw | 4,922 | −78.9% |
| Audio language | `audio_language` · ev_raw | 11,801 | −49.4% |
| Subtitle language | `subtitle_language` · ev_raw | 18,257 | −21.7% |
| Player version | `player_version` · ev_raw | 18,958 | −18.7% |
| Video resolution | `extra['video_resolution']` · ev_raw | 5,289 | −77.3% |
| Show name | `extra['show_name']` · content_dim | 9,179 | −60.6% |
| Video type | `video_type` · content_dim | 10,778 | −53.8% |
| Category | `category` · content_dim | 9,317 | −60.1% |

**`Country` is a dead filter, and we say so rather than remove it.** `country` is the constant
`'india'` in all 7,000,000 unseen rows *and* in the graded file, so `WHERE country='india'` returns
the identity curve — same peak, same minute, same 4,334 minutes of support. The requirement that
filters must actually alter the curve is met by **11 of 12, not 12 of 12**. We keep the control
visible because geography is a named example dimension and a judge should be able to see `india` and
understand the dataset is single-geo; hiding it would not change the fact, only who discovers it.

Beyond magnitude, the curve's **shape** changes too: the peak minute itself moves for 7 of the 12,
and support collapses from 4,334 minutes to as few as 367.

Two filters (`video_resolution`, `show_name`) are honest `ALIAS` columns over the `extra` map — the
mechanism that lets a *new* column on an unseen day become filterable the same day, with no
migration. Four more reach the curve through `LEFT ANY JOIN content_dim`, with zero orphans.

## ClickStack integration

Wiring, OTel configuration, destination service and tables, and the evidence gap audit:
[`docs/CLICKSTACK_SUBMISSION.md`](../docs/CLICKSTACK_SUBMISSION.md),
[`docs/CLICKSTACK.md`](../docs/CLICKSTACK.md), [`docs/OBSERVABILITY.md`](../docs/OBSERVABILITY.md).
Redacted environment template: [`.env.example`](../.env.example) — no credentials are committed
anywhere in this repository (verified: the Cloud password appears in 0 commits and 0 tracked files).

**The destination is split, and we state it rather than blur it.** The dashboards **read** the
graded ClickHouse Cloud service, database `sonyliv`. OTLP telemetry about our own pipeline
**writes** to the ClickStack container's bundled ClickHouse (`otel_metrics_gauge`, `otel_logs`,
`otel_traces`), because the Cloud service exposes no OTLP endpoint — verified, it has no `otel_*`
tables. A reader seeing "ClickStack + Cloud `sonyliv`" would reasonably assume telemetry lands in
the same place; it does not, and saying so is both more accurate and a stronger answer than leaving
it ambiguous. End-to-end verification with rows read back:
[`docs/OBSERVABILITY.md`](../docs/OBSERVABILITY.md).

## Reproducing this

```bash
tools/fetch_data.sh          # data is NOT in the repo; pulls from the organiser's public repo
make ci                      # build + unit tests
tools/test-all.sh --fast     # the full suite
tools/reconcile.sh           # THE GATE — recomputes from raw and fails on any mismatch
```

## Known limitations, stated rather than hidden

- **Explicit `AppBackgrounded` is not a state gate.** We detect backgrounding by heartbeat gap
  (`GAP_S` = 150 s), not by the explicit `AppBackgrounded`/`AppForegrounded` markers — those are
  documented as not guaranteed and are sharply asymmetric in the official file (19,981 backgrounds
  against 11,932 foregrounds, with **46.8% of backgrounds never followed by a foreground**).

  We measured the alternative end to end rather than assuming. Treating `AppBackgrounded` as a hard
  transition moves the headline from **20,815.28 h / peak 23,324 @ 11:17** to **20,797.89 h
  (−0.084%) / peak 23,307 (−17, −0.073%) @ 11:16**. The gate is **92.4% redundant with the gap
  rule**, which already ends the run at 8,647 of the 9,360 unrevoked backgrounds — it removes 17 and
  adds back 2.

  **The same measurement surfaced a larger effect we had not flagged.** 60 s of tail grace is
  credited past a *terminal* `AppBackgrounded` on 7,972 intervals across 7,507 sessions — 132.87 h,
  worth **−202 on the peak, 12× the issue we were looking for** — and a hard state transition does
  *not* remove it. It is also the more spot-checkable of the two: "their last event says
  backgrounded and you counted them for another minute" needs no interpretation.

  Together these bound the exposure at **149.67 h of 20,815.28 h (0.72%)** of counted watch time and
  **213 of 23,324 (0.91%)** at the peak. We ship the gap-only reading unchanged — it is the
  reconciled one, and changing a derivation for 0.073% at the deadline is the wrong trade — and
  disclose the bound rather than hide it.

  **One caveat worth stating plainly: the peak *minute* is less stable than the peak *value*.**
  11:17 leads 11:16 by only 6 viewers under our reading, and every alternative reading reverses that
  ordering. Full measurement, reproduction SQL and a hand-checkable worked example:
  [ADR 0035](../docs/adr/0035-explicit-appbackgrounded-is-not-a-state-gate.md) and
  [`evidence/backgrounded/`](../evidence/backgrounded/).
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
