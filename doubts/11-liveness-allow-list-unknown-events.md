# 11 · Which events prove liveness? Small on this file (−1.3%) — unbounded on the unseen day

> **Summary:** Every event in `ev_raw` renews activity and can earn 60 s of tail credit — `VideoError`,
> `AppBackgrounded`, seeks, resizes, telemetry bursts, **and any event value we have never seen**.
> Restricting liveness to an allow-list (`VideoHeartbeat` + `VideoPlay`) moves the headline only
> **2,917 → 2,880 (−37, −1.3%)** — the broad-liveness criticism (Codex 003 §7.2.1) is theoretically
> right and practically small *on this file*. The live risk is §7.2.9: **unknown events fail open**,
> so a new event value on the unseen day would silently inflate our answer with no gate noticing —
> the gate shares the model's vocabulary. The defence is cheap and needs no ruling: a committed
> vocabulary contract ([evidence/liveness/vocabulary.tsv](../evidence/liveness/vocabulary.tsv), 47
> pairs, enumerated for the first time) that the loader checks, alerting on anything new.

**Status:** **PARTLY ANSWERED** — the unknown-event default is decided and applied
([ADR 0033](../docs/adr/0033-event-semantics-are-declared-and-unknown-events-fail-closed.md),
cost zero on this file); the known-event allow-list (−1.3%) is still open. See **Answer** below ·
**Evidence measured:** 2026-08-01/02, scratch `liv_q28` and `evsem_q33`
([evidence/liveness/](../evidence/liveness/README.md)); baseline reproduces the graded
2,917 / 1,978.1 h exactly.

---

## The evidence

### 1 · What grants liveness today

`sql/30_build_intervals.sql` walks **all** event timestamps: `ts` is `groupArray` over every row of
the session. Only three values carry semantics (`pause`, `resume`, `VideoSessionEnd`); the other 44
of the file's 47 distinct `(event_type, event)` pairs participate as anonymous timestamps that
bridge gaps and, when last in a run, earn `TAIL_S = 60`. `docs/DATA_DICTIONARY.md` documents this as
deliberate policy — but until this audit the full vocabulary was written down nowhere, so there was
no definition of "unknown" to alert on.

### 2 · The measured exposure on this file

Single-line variants of the `ts` aggregation, full rebuild each
([evidence/liveness/README.md](../evidence/liveness/README.md) Q1):

```
                                              hours     peak
 baseline — every event renews (shipped)      1,978.1   2,917
 bg/fg no longer renew                        1,987.1   2,905   −12 · −0.4%
 bg/fg + VideoError no longer renew           1,987.0   2,905   −12 · −0.4%
 allow-list: only VideoHeartbeat + VideoPlay  1,961.5   2,880   −37 · −1.3%
```

Of 3,925 gaps > 150 s between consecutive allow-listed events, only **147 are genuinely bridged** by
excluded events (7.1 h) — nearly all by bg/fg. `VideoError` bridges exactly **2**. The one corner
that is hard to defend: **2,392 runs (16%) end at an `AppBackgrounded`** and each collects 60 s of
tail *after the viewer demonstrably backgrounded* — ≈ 39.9 h booked into known-background time
(this corner is also half of [doubts/10](10-fail-closed-state-gates.md)'s foreground gate).

Hours move *up* +9.0 h when bg/fg stop renewing (shorter runs → unclosed pauses eat less, extra
splits mint tails) while the peak moves down — the constants interact, as the adversarial ledger
(row 6) already established.

### 3 · Why the unseen day changes the calculus

On this file the exposure is bounded because we can enumerate what exists. On the unseen day it is
not: the statement promises new data, and **an event value we have never seen inherits full
liveness-granting power silently** — it bridges gaps, extends runs, earns tail. No gate notices,
because `90_reconcile.sql` recomputes truth from the same `ev_raw` with the same "every timestamp
counts" convention. A hypothetical `SystemSleep` or `WidgetPing` emitted every 30 s while the phone
is locked would turn dead time into watch time on both sides of the reconcile at once.

Scale of the precedent in this file: bg/fg — events that carry no playback meaning — contribute
0.4% of the peak by pure timestamp presence. A chattier non-playback stream would contribute more,
and we would not know until scored.

### 4 · Why the gate goes green regardless

The gate's truth side shares the model's event vocabulary by construction. 17,028 green minutes say
nothing about whether the *right* events granted the liveness. Only a vocabulary contract checked at
the boundary can.

## Exactly what to ask

> "Which events prove a viewer is actively watching? Concretely: should a `VideoError`, an
> `AppBackgrounded`, or a seek keep a session's activity alive across a heartbeat gap and earn
> post-event grace, or do only playback signals (heartbeats, play) count? And on the unseen day, if
> a new event type appears that we have never seen, should it extend activity by default or be
> excluded until reviewed? On the provided file the strict reading is worth −1.3% of peak; for
> unseen event types the exposure is unbounded."

## Why this is worth mentor time

Not primarily for the −37: for **the default**. Fail-open vs fail-closed on unknown vocabulary is a
one-word ruling that determines whether the unseen day can silently inflate our number. It is also
the cheapest question on the list to act on either way — the allow-list is a one-line `IN` in the
`ts` aggregation, already built and measured as `liv_q28.si_allowhb`.

## How the answer changes what we build

| Answer | Change |
|---|---|
| Every event proves liveness (our assumption) | Nothing in the model. **Still add the load-time vocabulary alert** (below) so a new value is at least surfaced — that needs no ruling. |
| Only playback signals (allow-list) | The `ts` line in `sql/30_build_intervals.sql` gains `groupArrayIf(…, event_type IN ('VideoHeartbeat','VideoPlay'))`; mirror in `90_reconcile.sql`; rerun `/reconcile`. Peak 2,880. `vocabulary.tsv` becomes the model's `IN` list. |
| Playback + explicit app-state events, unknown excluded | Same edit with bg/fg retained in the list (peak 2,917 −0 on this file since bg/fg then still renew); the alert covers the rest. |
| Unknown events must fail closed (whatever renews today) | Loader guard only — no model change on this file, hard fail on new vocabulary on the unseen day, human decides per value. |

**The proposed defence, needing no mentor at all** (proposal only — owners of `tools/load.sh` /
`tools/unseen-verify.sh` implement): commit `vocabulary.tsv` as the contract; at load, one
`throwIf`-guarded query fails on any `(event_type, event)` pair not in it. Cost: a 48-line TSV, a
sub-second query, ~15 lines of shell. Same shape as the challenger's source-contract gate the
bake-off already voted to cherry-pick (§5.2a) — this supplies the concrete contract it was missing.

## Our current assumption

Every **declared** event renews liveness; **undeclared events now fail CLOSED**
([ADR 0033](../docs/adr/0033-event-semantics-are-declared-and-unknown-events-fail-closed.md), applied
2026-08-02). Shipped in model and gate; the contract is
[`contracts/event_semantics.tsv`](../contracts/event_semantics.tsv), derived pair-for-pair from
`evidence/liveness/vocabulary.tsv`.

## Answer

**Half of this question no longer needs a mentor — it is answered and applied. Half still does.**

**ANSWERED (ADR 0033, 2026-08-02): the unknown-event default.** Undeclared pairs renew nothing. The
rule is *an event we have not declared may only shorten the answer, never lengthen it* — so liveness
is fail-closed by pair, while `pause` stays matched by declared NAME so an undeclared `AdBreak/pause`
still stops the clock. `tools/validate-source-contract.sh` probe 8 was promoted **WARN → FAIL** and
now reports, for each undeclared pair, how many of its events have no declared event within 150 s.

Measured cost of that flip on the delivered file: **zero.** 30,323 intervals · 1,978.1 h · peak
**2,917 @ 2026-07-26 10:56**, interval boundaries bit-identical to the pre-0033 build, gate green over
17,028 minutes. Measured value: an undeclared `AppKeepalive/tick` every 30 s for 30 min past each
session's last event takes the fail-open peak to **5,004 (+71.5%)** and moves the peak minute; two
other plausible injections move it *down* by 29 and 52 — **the sign is not predictable**, which is a
stronger argument than the "silently inflates" framing above. Ledger:
[evidence/event-semantics/](../evidence/event-semantics/README.md).

**STILL OPEN: which of the events we HAVE seen prove watching.** That is the −1.3% in the tables
above, it moves a submitted number, and it is an operator/mentor call. It is now a one-word edit —
the `LIVENESS_CLASSES` line in `sql/30_build_intervals.sql` and `sql/90_reconcile.sql` — with the full
ladder measured and committed beside it:

```
 playback lifecycle app_state error download ui   30,323  1,978.1 h  2,917  <- ships
 playback lifecycle download ui                   29,659  1,987.0 h  2,905
 playback lifecycle                               29,659  1,987.0 h  2,904
 playback download ui                             29,343  1,961.5 h  2,880   (= the allow-list row above)
 playback                                         29,340  1,961.5 h  2,879
```

Ask the mentor question at the top of this file unchanged, minus its last sentence about unseen event
types — that half is closed.
