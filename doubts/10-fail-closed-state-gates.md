# 10 · Lease semantics or fail-closed state gates? Two implementations agree it is worth ~11%

> **Summary:** Our model grants activity as a **lease** — any event renews it, gaps and explicit
> pauses revoke it. The alternative is **fail-closed state gates**: a second counts only while
> foreground AND playing are both provably open. Implemented inside our own derivation, fail-closed
> reads **peak 2,606 vs 2,917 (−311, −10.7%) and 1,720.3 h vs 1,978.1 (−13.0%)**. The competing
> branch's independent implementation reads 1,762.4 h — **within 2.4% of our fail-closed number** —
> so two unrelated codebases agree the semantic fork is worth ~11–13%, second only to minute
> membership ([doubts/09](09-minute-membership-instant-reading.md), −14.1%). The gate cannot see it:
> both readings reconcile green against their own conventions.

**Status:** open · **Evidence measured:** 2026-08-01/02, scratch `liv_q28`
([evidence/liveness/](../evidence/liveness/README.md)); baseline reproduces the graded
2,917 / 1,978.1 h exactly. Corroborated by `docs/design-bakeoff.md` §2 and Codex 003 §7.2.1–3.

---

## The evidence

### 1 · The two readings

- **Lease (shipped):** a run of events with no gap > 150 s is active; explicit pause windows are
  subtracted; everything else — backgrounding observed, playback state, session ended — is inferred
  from gaps or ignored. Fails **open**: when signals are ambiguous, time counts.
- **Fail-closed:** a second counts only while two independent state machines are both open —
  **foreground** (closed at `AppBackgrounded`, reopened at `AppForegrounded`, unclosed → excluded)
  and **playing** (open at `VideoPlay`/`resume`, closed at `pause`/`VideoSessionEnd`). Liveness
  renewal restricted to playback telemetry (`VideoHeartbeat`/`VideoPlay`). Fails **closed**: when
  signals are ambiguous, time does not count.

Both are defensible readings of "excluding backgrounded, paused and heartbeat-missing periods."
The lease model argues bg/fg events "are not guaranteed" (they do not pair: 14,700 vs 14,321 —
ADR 0001) so gaps are the honest signal. Fail-closed argues an *observed* `AppBackgrounded` is
still evidence, whatever the pairing rate — Codex 003 §7.2.2 makes exactly this point: missing
pairs justify not *requiring* a pair; they do not prove an observed background should be ignored.

### 2 · The delta, measured on OUR implementation

The bake-off number (challenger 1,762.4 h, −10.9%) was measured on the challenger's own code, so
semantics and implementation were confounded. `evidence/liveness/fail-closed-variant.sql` applies
the fail-closed rules inside our shipped derivation — same harness, same gate-semantics metrics:

```
                                   intervals   hours     peak
 baseline (lease, shipped)           30,323    1,978.1   2,917  @ 10:56
 fail-closed, all gates              27,818    1,720.3   2,606  @ 10:56   −311 · −10.7%
 fail-closed minus foreground gate   29,078    1,791.2   2,704  @ 10:56   −213 · −7.3%
```

Decomposition: the foreground gate is worth **−98 peak / −70.9 h** inside the composite; the
playing gate + terminal end + liveness allow-list carry −213. The perverse corner the lease model
accepts: **2,392 of 14,954 runs end at an `AppBackgrounded`** and each collects 60 s of tail credit
*after the viewer demonstrably backgrounded* (≈ 39.9 h booked into known-background time).

### 3 · Two independent implementations, one number

```
 our fail-closed rebuild        1,720.3 h   (this dossier)
 challenger branch, its code    1,762.4 h   (docs/design-bakeoff.md §2)
 shipped lease model            1,978.1 h
```

The two fail-closed implementations were written by different agents, from different code lineages,
hours apart, and land within 2.4% of each other — while both sit ~11–13% below shipped.
The residual 42.1 h between them is implementation detail (tie-breaks, boundary rules); the ~250 h
gap to shipped is **semantics**. That rules out "the challenger's number is a bug" as an answer.

### 4 · Why the gate goes green under either

`sql/90_reconcile.sql` recomputes truth from `ev_raw` with the model's own conventions — the lease,
the tail, the liveness set. A fail-closed model with a fail-closed gate would also compare 0
mismatched. 17,028 green minutes carry zero evidence on this question; only the ground-truth
generator's convention decides it.

## Exactly what to ask

> "When the app reports `AppBackgrounded` and heartbeats continue for a while, does the viewer count
> until the heartbeats stop (our reading: gaps detect backgrounding), or does the explicit
> background event end foreground time immediately (state-gated reading)? Similarly, does time
> between session start and the first `VideoPlay` count as watching? The two readings differ by
> **~11% of peak concurrency and 13% of watch hours** — and two independent implementations of the
> strict reading agree with each other within 2.4%."

## Why this is worth mentor time

It is the **second-largest fork we have measured** (−311 peak; only doubts/09's −410 is bigger),
and unlike most dossiers it carries corroboration: an independently-built implementation lands on
the same answer. If the private truth was generated by a state machine over bg/fg and play/pause —
the natural way to *spot-check* raw events — every number we submit is systematically ~11% high and
no internal check can tell us.

## How the answer changes what we build

| Answer | Change |
|---|---|
| Lease / gap-based (our assumption) | Nothing. Record the ruling in ADR 0007 and close doubts/10. |
| Fail-closed state gates | Port the rules from `evidence/liveness/fail-closed-variant.sql` into `sql/30_build_intervals.sql` (it is the same file shape — one CTE changes), mirror in `90_reconcile.sql`, rerun `/reconcile`. Peak 2,606. The bake-off's reversal clause (§6, "port the rules, not the branch") already anticipates exactly this. |
| Foreground gate only (bg is a close transition, play state ignored) | The `fc_nofg` decomposition bounds it: ship the bg/fg window subtraction only; peak lands between 2,704 and 2,905 depending on liveness set; re-measure the exact combination before shipping. |
| Playing gate only | Measure the single-gate variant with the same harness (one run); not built today because no reviewer proposed it alone. |

## Our current assumption

Lease semantics: any event renews activity, gaps revoke it, observed bg/fg events carry no
transition semantics (ADR 0001/0007). Shipped in model and gate; every graded number rests on it.

## Answer

_unrecorded_
