# 12 · The spec's background/foreground events: we ignore 29,021 of them — measured worth ≤2.5%

> **Summary:** The organiser's data dictionary names `AppBackgrounded`/`AppForegrounded` and the
> problem statement offers them as a way to cut inactive segments; our model ignores all 29,021 and
> infers backgrounding from heartbeat gaps (ADR 0007). Measured: of **916.3 h** the events mark as
> backgrounded, gaps + pause windows already exclude **96.8%** — 75.4% of backgrounds arrive ≤10 s
> after an explicit `pause`, so the signals catch the **same population**. Using the events directly
> moves the headline **−45 to −74 peak (−1.5%…−2.5%)** depending on construction, over half of which
> is the 60 s tail credited after an explicit background (−37), not the windows (−8). Unmatched pairs
> recounted: **337**, worth ≤3 viewers under any closing rule. ADR 0007 is vindicated by measurement;
> the open question is only whether judge spot-checks interpret state transition-style.

**Status:** open · **Evidence measured:** 2026-08-02, scratch `exs_q12`
([evidence/explicit-state/](../evidence/explicit-state/README.md)); baseline reproduces the graded
2,917 / 1,978.1 h / 30,323 intervals exactly. Extends [doubts/07](07-tail-credit-at-explicit-stops.md),
[doubts/10](10-fail-closed-state-gates.md), [doubts/11](11-liveness-allow-list-unknown-events.md);
flagged by Codex 003 §7.2.2 and `docs/design-bakeoff.md`.

---

## The evidence

### 1 · The divergence

`docs/upstream/PROBLEM_STATEMENT.md` says the dataset contains *"playback-state markers (playing,
paused, backgrounded, foregrounded)"* and its solution directions name *"background/foreground
events"* for cutting inactive segments. The graded data carries 14,700 `AppBackgrounded` +
14,321 `AppForegrounded`. References to either in `sql/30_build_intervals.sql` and
`sql/90_reconcile.sql`: **zero.** ADR 0007 defended this (events "not guaranteed", pairs unmatched,
gaps measured to work) but never priced the alternative. This dossier prices it.

### 2 · The signals agree — gaps already exclude 96.8% of explicitly-marked background time

Intersecting every explicit bg→fg window with the shipped model's active intervals: 916.3 h marked
backgrounded, **29.3 h (3.2%) still counted as watching**. The mechanism: **11,086 of 14,700
backgrounds (75.4%) are preceded within 10 s by an explicit `pause`** — the OS pauses playback on
backgrounding — so our pause windows already exclude the time, and heartbeats then stop (ADR 0007
GATE ①). The explicit events are *redundant with*, not *orthogonal to*, the signals we use. We have
not been excluding the wrong time.

### 3 · What using them directly would do

Three constructions, all built inside the shipped derivation
([evidence/explicit-state/README.md](../evidence/explicit-state/README.md) for the full table):

```
                                              hours     peak
 baseline (shipped: gaps + pauses)            1,978.1   2,917  @ 10:56
 literal transitions (bg closes, fg reopens)  1,945.8   2,872  −45 · −1.5%
 conservative union (gaps AND events)         1,935.9   2,843  −74 · −2.5%
 explicit events only, gaps ignored           1,946.2   2,852  −65 · −2.2%
```

Every variant keeps the peak minute at 2026-07-26 10:56. Decomposition: the bg→fg windows alone are
**−8 peak**; the rest is mostly the **tail rule** — 2,392 runs end at an `AppBackgrounded` and each
collects 60 s of grace after the viewer left; capping tail at the next bg is −37 / −22.0 h on its
own (the bg-flavoured sibling of doubts/07's −141). And the striking third row: a model with **no
gap heuristic at all**, driven purely by the explicit markers, lands within 2.2% of ours — the two
philosophies converge on this data.

### 4 · The unmatched-pair objection is priced at noise

Per-session recount: **337** backgrounds never see a foreground (ADR 0007's "379" was the global
count difference), 29 orphan foregrounds, and every one of the 10,866 sessions carries bg events.
The three plausible unclosed rules (stay closed to run end / next event / next heartbeat) span
**3 viewers of peak and 1.3 h** end to end. "The pairs don't match" is true and costs nothing.

## Exactly what to ask

> "The statement offers background/foreground events for cutting inactive segments; we instead
> infer backgrounding from heartbeat gaps plus explicit pauses, and we measured the two approaches
> agreeing on 96.8% of backgrounded time — using the events directly would move our peak only
> −1.5% to −2.5% depending on construction. Will judges walk the explicit
> bg/fg (and pause/resume) markers as state transitions? If so, which reading closes an interval:
> the background event alone, or background-or-gap, whichever comes first? And does post-event
> grace (our 60 s tail) survive an explicit background?"

## Why this is worth mentor time

Not for the delta — for the *direction*. Under exact raw-event spot-checks, a systematic
+1.5…2.5% is pure loss if the truth generator walked the markers transition-style (the natural way
to *generate* truth from these events). One sentence from a mentor picks between "your gaps
reading is what we graded" (keep, and cite the 96.8% agreement as design evidence) and "truth is
transition-generated" (port a one-CTE change, already built and measured). It also closes half of
doubts/10's scope: this audit shows the fail-closed −311 is mostly play-state and liveness, *not*
the background markers.

## How the answer changes what we build

| Answer | Change |
|---|---|
| Truth uses gaps/lease semantics (our assumption) | Nothing. Record in ADR 0007, close this and the bg/fg half of doubts/10; the 96.8% agreement number goes in the submission as design-quality evidence. |
| Truth walks explicit transitions (bg closes, fg reopens) | Port `evidence/explicit-state/sql/v1_transitions.sql` rules into `sql/30_build_intervals.sql` (same file shape — window concat + tail cap), mirror in `90_reconcile.sql`, `/reconcile`. Peak 2,872. |
| Both signals, whichever first | Same port from `v2_union.sql` (adds the bg/fg liveness exclusion from doubts/11's list). Peak 2,843. |
| Tail must not survive an explicit stop (any kind) | That ruling belongs to doubts/07; the bg cap alone is −37 and composes with 07's −141 (partial overlap — measure the union before shipping both). |

## Our current assumption

Backgrounding is inferred from heartbeat gaps; pauses from explicit pause/resume; bg/fg events carry
no transition semantics and merely renew liveness like any event (ADR 0001/0007, and doubts/11 for
the liveness half). Shipped in model and gate; every graded number rests on it — now with the
measured defence that the explicit markers agree with it on 96.8% of the time they cover.

## Answer

_unrecorded_
