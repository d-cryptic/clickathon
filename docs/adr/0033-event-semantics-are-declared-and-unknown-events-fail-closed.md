# ADR 0033 — Event semantics are declared, and an undeclared event fails closed

> **Summary:** The model treated **every** event as proof of watching, including `(event_type, event)`
> pairs **we have never seen** — they bridged gaps, extended runs and earned 60 s of tail, and no gate
> could notice because `sql/90_reconcile.sql` shares the model's vocabulary. All 47 pairs are now
> **declared** in `contracts/event_semantics.tsv`, compiled into the model, the gate and the load-time
> source-contract gate from that one file; an **undeclared pair renews nothing** (fail-closed).
> **Cost on the delivered file: zero** — 30,323 intervals · 1,978.1 h · **PEAK 2,917 @ 2026-07-26
> 10:56**, boundaries bit-identical to the pre-0033 build, reconcile green over 17,028 minutes.
> **Value: measured.** An undeclared `AppKeepalive/tick` takes the fail-open peak to **5,004 (+71.5%)**
> and moves the peak minute; under the contract the answer is unchanged. Probe 8 of the source-contract
> gate is promoted **WARN → FAIL** and now reports how much is at stake. Status: accepted, 2026-08-02.

**Status** Accepted · 2026-08-02 · branch `feat/event-semantics-contract` · measured on local scratch
`evsem_q33`, rebuilt verbatim from `default.ev_raw` (905,558 events) · **nothing here was applied to
graded `sonyliv`, which was neither written nor read** · full ledger:
[`evidence/event-semantics/README.md`](../../evidence/event-semantics/README.md)

## Context

`sql/30_build_intervals.sql` derives runs from `groupArray(toUnixTimestamp(event_timestamp))` — **every
row of `ev_raw`**. Only three values ever carried meaning (`pause`, `resume`, `VideoSessionEnd`); the
other 44 of the file's 47 distinct pairs participated as anonymous timestamps. `docs/DATA_DICTIONARY.md`
recorded that as deliberate policy, and [evidence/liveness](../../evidence/liveness/README.md) measured
what the strict reading would cost: **−37 peak, −1.3%**. Small.

The exposure that is not small is the one [doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md)
raised and [Codex validation 008 §P1](../codex-validation/008-current-main-genericity-and-upstream-closure.md)
independently asked for: **an event value we have never seen inherited full liveness-granting power,
silently.** On the delivered file we can enumerate what exists. On the unseen day we cannot, and the
gate cannot help — `90_reconcile.sql` recomputes truth from the same `ev_raw` under the same "every
timestamp counts" convention, so a new chatty event value would move both sides of the comparison at
once and 17,028 green minutes would prove nothing.

Two questions were tangled in that, and this ADR deliberately separates them:

- **Which of the events we HAVE seen prove watching?** Worth −1.3% of a submitted number. Not ours.
  It stays [doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md), open, with a mentor
  question and now a measured ladder attached.
- **What happens to an event we have NOT seen?** Worth nothing on this file and unbounded on the
  next. Decided here.

## Decision

### 1 · One declared contract, three consumers, one reader

[`contracts/event_semantics.tsv`](../../contracts/event_semantics.tsv) declares every
`(event_type, event)` pair with a **class** and an **action**:

| column | values | what it drives |
|---|---|---|
| `class` | `playback` · `lifecycle` · `app_state` · `error` · `download` · `ui` | whether the pair renews liveness, via `LIVENESS_CLASSES` |
| `action` | `none` · `pause` · `resume` · `end` | the state markers: pause window open/close, `is_open` |
| `note` | prose | why, and every "this is deliberately NOT a pause" |

47 rows, grounded pair-for-pair in [`evidence/liveness/vocabulary.tsv`](../../evidence/liveness/vocabulary.tsv)
(the enumeration is the evidence; the classification is the decision). `tools/event-semantics.sh`
renders it into three places and is the **only** reader:

```
contracts/event_semantics.tsv
   ├── --write ──> sql/30_build_intervals.sql   generated block, model
   ├── --write ──> sql/90_reconcile.sql         generated block, gate
   └── --pairs ──> queries/validate_source_contract.sql   load-time probe 8
```

It is **inlined**, not placeholder-substituted, because every `sql/*.sql` in this repo must stay
runnable as-is through `tools/ch` — `queries/validate_source_contract.sql` already pays that price and
says so in its own header, and a rebuild at 2am must not need a renderer. The duplication is made safe
by `tools/event-semantics.sh --check`, now the `evt-semantics` suite in `tools/test-all.sh`: it fails
if either file's block differs from the TSV, **and** if the two files carry different hand-edited
`LIVENESS_CLASSES`. Both failures were exercised live, not asserted (evidence §5).

### 2 · The default for an undeclared pair: fail closed — "unknown may only subtract"

An undeclared pair contributes **no timestamp** to the run array. It cannot bridge a gap, extend a
run, or mint a `TAIL_S`. It is still read as a dimension observation.

The rule is stated as a direction rather than a mechanism, because the mechanism has to be *asymmetric*
to obey it:

> **An event we have not declared may only shorten the answer, never lengthen it.**

- **Liveness — fail-closed by pair.** Undeclared ⇒ no liveness ⇒ under-count. Safe.
- **`pause` / `resume` — matched by declared NAME, not by pair.** An undeclared `AdBreak/pause`
  arriving on the unseen day still **stops the clock**, which is the same shortening direction. Had we
  made markers fail-closed by pair, an unrecognised pause would have been ignored and the model would
  have booked paused time as watch time — fail-closed on liveness and fail-closed on pause point in
  *opposite* directions, and only one of them is conservative. A genuinely new *name* (`unpause`) is
  undeclared either way and leaves the pause open to the run end: also shortening.
- **`end` — matched on declared `event_type`.** An unrecognised end marker leaves `is_open = 1`, so the
  session stays correctable rather than being sealed early. Also not an inflation.

The one residual: an undeclared *type* emitting a **known** `resume` name closes a pause window and so
lengthens. It needs a matching `pause` to have any effect at all, and probe 8 fires on the pair before
the load. Recorded rather than engineered around.

### 3 · The known-event policy ships unchanged, with the ladder measured

`LIVENESS_CLASSES` defaults to all six classes — exactly the pre-0033 behaviour. Measured alternatives
(evidence §1) are in the file as a comment, ranging to **2,879 (−1.3%)**. Not applied: narrowing it
moves a number we have already submitted, which is an operator's call, not a build's. Same discipline
as `POINT_ACTIVITY_COUNTS` ([ADR 0031](0031-point-activity-user-attribution-and-the-densify-recipe.md)).

### 4 · The load-time alert is promoted to FAIL and made quantitative

`queries/validate_source_contract.sql` probe 8 was `WARN — vocabulary drift: unknown event values`,
scoped to unknown sub-values under a **known** type. It is now:

`FAIL — undeclared (event_type, event) pair`, scoped to **any** pair the contract does not declare, and
its note carries the pair list, the counts, and a **`solo`** figure: undeclared events with no declared
event within 150 s either side — the instants where fail-open and fail-closed genuinely disagree.

FAIL does not mean "the load is unsafe". Under fail-closed the load is the safe direction, and the note
says so. FAIL means **a human owes this file a semantic ruling before the number is submitted** — the
thing doubts/11 found nothing was forcing. A WARN in a 25-row report at 2am forces nothing.

## Consequences

### What it costs

**Nothing we would submit.** 30,323 intervals · 1,978.1 h · **PEAK 2,917 @ 2026-07-26 10:56**, and the
interval boundaries are **bit-identical** to the pre-0033 build — 0 rows differ across all twelve
non-`build_version` columns. The contract-driven gate against the serving layer the *pre-contract*
model built: `minutes_compared=17028 mismatched=0 max_abs_diff=0 peak=2917 PASS`. `tools/test-all.sh
--fast`: 9 suites, 9 PASS. Rebuild cost is unchanged (sub-second on 905,558 rows either way); the
liveness test is a constant-folded array membership, not a join.

### What it buys, measured

Three undeclared pairs injected into a copy of `ev_raw` and rebuilt both ways (evidence §2):

| injected pair | fail-open peak | fail-closed peak |
|---|---|---|
| `WidgetPing/ping` every 30 s across the session span (+40% rows) | 2,888 (−29) | **2,917** |
| `SystemSleep/lock-screen-ping` every 60 s while backgrounded (+5.5% rows) | 2,865 (−52 · −1.8%) | **2,917** |
| `AppKeepalive/tick` every 30 s for 30 min past the last event (+72% rows) | **5,004 (+71.5%)**, peak minute moves to 11:15, 4,925.1 h (+149%) | **2,917 @ 10:56** |

Boundaries bit-identical to baseline in all three fail-closed builds. **The direction is not
predictable** — two of the three *reduce* the peak, because extra liveness merges runs and a longer run
gives the 23% of pauses that never resume more room to eat (ADR 0007). So fail-open is not a bounded
over-count that could be argued down after the fact; it is an unbounded perturbation of unknown sign.

### What it risks — the argument against, measured rather than asserted

Fail-closed under-counts, which is the safe direction for a foreground-only metric. The real objection
is that a **wrongly classified common event** would be expensive. Measured by 47 full rebuilds, each
omitting exactly one declared pair (evidence §3): the range of a single misclassification is
**−131 to +18 peak** (−92.7 h to +21.6 h). Worst case `VideoHeartbeat/network-bandwidth`, −4.5%.

Two findings that change how the TSV must be reviewed:

1. **Volume is not weight.** The three highest-volume pairs — 53.7% of the entire file between them —
   are worth ≤2 peak each, because they are redundant with one another. `network-bandwidth` is 3.4% of
   events and worth 131: of 5,247 gaps > 150 s between other events, **1,170 contain a
   `network-bandwidth` event**. It fires exactly when nothing else does. A reviewer sorting the
   contract by event count will look straight past the pair that matters.
2. The worst misclassification (−4.5%) is **smaller than the worst measured fail-open surprise
   (+71.5%)**, one-sided per pair, bounded, and *visible* — it is a line in a reviewed 47-line file,
   where fail-open is silent by definition.

### What it does not fix

- **Dimension attribution still reads every row.** An undeclared pair cannot move the total curve but
  can still move a *filtered* answer: under the most extreme injection, 1,337 of 30,323 intervals get a
  different `audio_language`. Gating attribution too would leave an undeclared-only interval with no
  dimensions at all, which is worse. Stated, not fixed.
- **A wrong contract is still invisible to the gate.** The gate shares the vocabulary by construction,
  so it can catch *divergence* (via `--check`) but never *wrongness*. Probe 8 at the boundary is the
  only defence, and it defends against *undeclared*, not against *misdeclared*.
- **The known-event question.** doubts/11 stays open; this ADR only answers the unknown-event half.

### Newly visible open questions

Writing the classification down forced three judgements that were previously nobody's:

- `VideoHeartbeat/AdPause` (45 events) and `VideoHeartbeat/speed-pause` (380) are **not** treated as
  pauses — the model pauses on `event = 'pause'` only. Declared `action=none` to preserve behaviour,
  flagged in the TSV `note`. Unmeasured.
- `download_*` (6 pairs) and `chromecast_*` / `premium_button_click` are classed `download` / `ui`
  rather than `playback`: a background download or a cast handoff is not evidence that *this* device is
  presenting video. They still renew liveness under the shipped policy, so this costs nothing today; it
  exists so a ruling can act on it (`playback lifecycle` = 2,904).
- `VideoSessionStart` is declared `action=none`, not `start`: the model derives starts from event
  timestamps, and declaring an action the model does not consume would make the contract lie.

## Alternatives rejected

- **A versioned ClickHouse table or dictionary** (Codex 008's literal suggestion). It would require a
  `CREATE` in the graded database and would make `sql/30_build_intervals.sql` fail against any database
  that had not been migrated — including every scratch database every suite builds. A committed TSV with
  a checked renderer gives the same versioning through git, with no schema change.
- **Leaving the default fail-open and relying on the alert alone** (doubts/11's minimum proposal). The
  alert is advisory and the pipeline runs anyway; injection C shows what running anyway is worth.
- **Applying the allow-list at the same time** (peak 2,880). That is the −1.3% decision, and bundling it
  would have made a zero-cost safety fix indistinguishable from a change to a submitted number.
- **Making markers fail-closed by pair, for symmetry.** Symmetric in code, opposite in effect: it would
  let an undeclared pause name book paused time as watch time. Rejected on the direction rule.

## References

- [doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md) — the dossier, the mentor wording,
  and the −1.3% that is still open
- [evidence/liveness/](../../evidence/liveness/README.md) — the 47-pair enumeration and the Q1 ladder
  this reproduces exactly
- [evidence/event-semantics/](../../evidence/event-semantics/README.md) — every number in this ADR
- [Codex validation 008 §P1](../codex-validation/008-current-main-genericity-and-upstream-closure.md)
- [ADR 0026](0026-hostile-input-quarantine-over-rejection.md) *(source-contract gate)* ·
  [ADR 0031](0031-point-activity-user-attribution-and-the-densify-recipe.md) *(the ship-the-old-default
  discipline)* · [ADR 0007](0007-gate-answers-pause-needs-explicit-handling.md) *(why pause is explicit)*
