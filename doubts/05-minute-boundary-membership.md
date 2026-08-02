# 05 · An interval that ends at exactly 10:56:00 — is that viewer in the 10:56 minute?

> **Summary:** Our model says yes: the delta path closes an interval at `toStartOfMinute(end) + 1`
> minute, so an interval ending **exactly on a minute boundary** is counted in the minute *starting*
> at that boundary. Under standard half-open overlap (`[start, end)` vs `[M, M+60)`) it has **zero
> overlap** with that minute and the answer is no. Measured: **505 intervals across 493 sessions**
> expose the case; the half-open reading moves **92 minutes** and **305 viewer-minutes**, and the
> graded peak moves **2,917 → 2,916**. `sql/90_reconcile.sql` uses the **same convention** as the
> serving SQL, so a green gate **cannot choose between the two readings**. **Deepens Q8 in
> [docs/MENTOR_QUESTIONS.md](../docs/MENTOR_QUESTIONS.md).**

> **Read with [09](09-minute-membership-instant-reading.md).** This dossier isolates the **end
> boundary** and is worth one viewer. 09 asks the broader form of the same question — any-overlap
> versus presence-at-the-instant — and is worth **410**. Both deepen mentor Q8; 09 is the one to ask
> first, and an answer to it may settle this one for free.

**Status:** open · **Evidence measured:** 2026-08-01, ClickHouse Cloud `sonyliv`, current model
(30,323 intervals · 1,978.1 h · peak 2,917 · gate green over 17,028 minutes)

---

## The evidence

### 1 · Where the convention lives — on BOTH sides of the gate

The serving path (`sql/40_deltas.sql`, the CLOSE branch) emits the −1 at the minute *after* the
end's minute, so minute `toStartOfMinute(e)` is always counted:

```sql
toDateTime((intDiv(e, 60) * 60) + 60) AS minute   -- the -1 lands one minute past the end's minute
```

The gate's independent truth (`sql/90_reconcile.sql`, `truth_min`) expands each segment
**inclusive of the end's minute**:

```sql
arrayJoin(range(intDiv(a, 60) * 60, (intDiv(b, 60) * 60) + 1, 60)) AS m   -- +1 ⇒ b's minute included
```

Same convention, independently implemented on both sides of the comparison. That is why this is a
dossier and not a bug report: **the gate is structurally blind here.** It proves serving matches our
derivation; if judges read the boundary the other way, every local gate stays green
(17,028 minutes, 0 mismatched) while every boundary minute is off. Nothing we can run distinguishes
the readings — only the graders can.

### 2 · The exposed population — exactly the uniform mass, so this is structural

```sql
SELECT countIf(toUnixTimestamp(interval_end) % 60 = 0)                       AS boundary_intervals,
       uniqExactIf(video_session_id, toUnixTimestamp(interval_end) % 60 = 0) AS boundary_sessions
FROM session_intervals FINAL;
-- 505 intervals, 493 sessions (of 30,323 / 10,866)
```

The end-second distribution is uniform — per-second buckets average **505.4** (range 454–550), and
the `:00` bucket holds **505**, dead on the uniform expectation. The boundary case is not a data
artefact or a clock quirk; it is the 1/60 of interval ends that any convention must land somewhere.
Composition: **347** end at an explicit `pause` stamped exactly `:00`, **165** are tail-credited run
ends (last event on a boundary, +60 s tail lands on the next one), 7 match both patterns.

### 3 · The half-open alternative, measured end to end

Both expansions over `session_intervals FINAL`, `uniqExact(video_session_id)` per minute; the only
difference is the last covered minute when `e % 60 = 0`:

```sql
-- inclusive (shipped):  range(intDiv(s,60)*60, intDiv(e,60)*60 + 60, 60)
-- half-open:            range(intDiv(s,60)*60, if(e % 60 = 0, e - 60, intDiv(e,60)*60) + 60, 60)
```

| | minutes differing | viewer-minutes | peak |
|---|---:|---:|---:|
| **inclusive — shipped** | | | **2,917** @ 10:56 |
| **half-open** | **92** | **−305** | **2,916** @ 10:56 |

The worst-hit minutes: 11:01 loses 10 viewers, 11:21 loses 9, three minutes lose 8. 36 minutes move
by 1, 56 by 2 or more. The peak minute itself loses exactly one viewer — **and the peak is the
graded number**.

*(The Codex audit ([codex-validation/001.md](../docs/codex-validation/001.md) §4.2) reported 91
minutes / 302 viewer-minutes for the same alternative — between the two grains measured here (§4)
and agreeing on direction and on the peak move. The grain sensitivity is the next section.)*

### 4 · The trap inside the alternative: two "half-open" implementations disagree

The serving layer merges each session's intervals at minute grain before emitting deltas — and the
merge fold stores `toStartOfMinute(interval_end)`, **discarding the seconds** that say whether the
end was on a boundary. So there are two places to apply the trim, and they differ:

| trim applied at | minutes differing | viewer-minutes | peak |
|---|---:|---:|---:|
| **per interval, before the merge** (the gate's truth grain) | 92 | −305 | 2,916 |
| **per merged run, after the merge** (what a naive `40_deltas.sql` edit would do) | 90 | −271 | 2,916 |

They differ because a boundary-ending interval can sit *mid-run*: trimming per interval can vacate a
minute that the merged run still covers. If the answer is "half-open", the fix must carry the raw
`interval_end` through the fold and trim **before** minute-truncation, in both `40_deltas.sql` and
`90_reconcile.sql` — otherwise the model and the gate implement two different half-opens and the
gate goes red for the wrong reason.

### 5 · The third reading, for completeness: sampling at the instant

Q8's other pole — "concurrent at minute M only if active at the **instant** M begins" — is not a
boundary trim, it is a different definition (an interval living entirely inside one minute touches
no boundary instant and vanishes). Measured:

```sql
-- covered minutes = boundary instants inside [s, e]:  range(ceil(s/60)*60, intDiv(e,60)*60 + 60, 60)
```

Peak **2,507** — a **14.1%** drop from 2,917. If judges sample rather than use overlap,
nothing about our current curve survives contact, which is why the question is worth asking even
though we consider this reading unlikely.

---

## Exactly what to ask

> "A definitional edge case that our own gate provably cannot decide. When a viewer's active period
> ends **exactly on a minute boundary** — active up to 10:56:00.000 and not a millisecond past it —
> do judge spot-checks count them as concurrent in the 10:56 minute?
>
> Read as 'they were active at an instant belonging to minute 10:56', yes. Read as half-open
> overlap — `[start, end)` against `[10:56:00, 10:57:00)` — the overlap is zero and the answer is
> no. Both are standard; we currently count them in.
>
> It matters more than it looks: 505 of our 30,323 intervals end exactly on a boundary (that is just
> the uniform 1/60 of ends — it will happen on the unseen day too), the two readings differ on 92
> minutes, and our **peak moves 2,917 → 2,916** — the difference is literally the graded number.
> And it is invisible to us: our reconcile gate recomputes truth using the same convention as the
> serving layer, so it stays green whichever reading you intended.
>
> **While we are at this boundary:** is 'concurrent at minute M' defined by *any overlap* with M, or
> by being active *at the instant M begins*? We assume any-overlap; instant-sampling would move our
> peak to 2,507."

---

## Why this is worth mentor time

**The two readings differ by exactly one viewer at the graded peak minute, and no measurement we can
make chooses between them.** Both are internally consistent; both are standard conventions; the
judge interpretation picks one and the file cannot tell us which. Our gate is structurally blind —
serving SQL and reconcile truth share the convention (§1), so a wrong guess is green locally and
wrong on every boundary minute of the benchmark and the unseen day.

It is also cheap to answer — one sentence, no answer-key leakage — and the answer settles an
implementation subtlety we would otherwise get wrong even while "fixing" it: the half-open trim must
happen before minute-merging or the model and the gate diverge from each other (§4).

## How the answer changes what we build

| If they say | We change | Cost | Effect on the headline |
|---|---|---|---|
| **"the boundary instant belongs to the minute it starts"** | nothing — shipped convention | zero | **2,917** stands |
| **"half-open — zero overlap does not count"** | carry the raw `interval_end` through the merge fold in `sql/40_deltas.sql` (it currently truncates to minutes) and suppress the last covered minute when `e % 60 = 0`, **before** the merge; the same rule in `sql/90_reconcile.sql`'s `truth_min`; rebuild + `/reconcile` | ~8 lines in two files + one rebuild | peak → **2,916**; −305 viewer-minutes across 92 minutes |
| **"concurrent means active at the instant M begins"** | replace the any-overlap expansion in both files with boundary-instant coverage; intervals contained inside one minute stop counting; new ADR — this is a different model, not a trim | derivation change + ADR + full re-measure | peak → **2,507** (−14.1%) |
| *no answer received* | keep the inclusive reading, and **state the envelope in the deck**: ±1 at the peak, 92 minutes, bounded by the boundary population — which `docs/RUNBOOK_UNSEEN.md` re-measures on the unseen day before submission | zero | turns a silent off-by-one on the graded number into a stated trade-off |

## Our current assumption

Any overlap counts, and the closing instant belongs to the minute it begins — an interval ending at
10:56:00 is concurrent at 10:56. Chosen originally by construction of the delta arithmetic, not by
argument; this dossier is what makes it a deliberate choice. Q8's assumption line ("any overlap
counts") stays true either way — this file pins down the boundary instant that Q8 leaves open.

## Answer

_unrecorded_
