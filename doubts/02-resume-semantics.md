# 02 · `resume` is not the opposite of `pause` — and the gap is 9.7% of our answer

> **Summary:** Our pause-exclusion rule closes a paused window at the **first `resume` after the
> pause**. Measured, `resume` fires for at least four different reasons — there are **9,958**
> back-to-back `resume→resume` runs and **900** sessions whose very first pause/resume event *is* a
> resume, so a resume does not imply a preceding pause. If the first resume after a pause is spurious,
> we close the window early and book the remainder as watch time. Measured end to end over the real
> file: the shipped rule counts **816.1 h** of paused time; the alternative reading counts **1,005.2 h**
> — a **189.2 hour** difference, **9.7%** of the 1,949.3 h we report. **This is larger than the
> unclosed-pause question (99.3 h / 5.09%) that ADR 0007 calls "the single largest unresolved number in
> the model."** It is not. This is. **Deepens Q3 in [docs/MENTOR_QUESTIONS.md](../docs/MENTOR_QUESTIONS.md).**

**Status:** open · **Evidence measured:** 2026-08-01, local `csv_audit.raw_str`, fresh CSV load

---

## The evidence

### 1 · The ledger does not balance, and it never could

```sql
SELECT countIf(event='pause') AS pauses, countIf(event='resume') AS resumes
FROM csv_audit.raw_str;
```

```
 pause   27,340
 resume  31,780      →  4,440 MORE resumes than pauses
```

If `resume` only ever meant "un-pause", these would be equal or resumes would be *fewer* (sessions
ending while paused). There are 4,440 **extra**.

### 2 · The smoking gun — resumes arrive in runs

Ordering each session's pause/resume events by timestamp and counting consecutive same-state pairs:

```sql
WITH per AS (
  SELECT video_session_id,
         arraySort(x -> x.1, groupArray((toInt64(event_timestamp), event))) AS a
  FROM csv_audit.raw_str WHERE event IN ('pause','resume') GROUP BY video_session_id)
SELECT
  sum(length(arrayFilter(i -> a[i].2='resume' AND a[i+1].2='resume', range(1, length(a))))) AS resume_resume,
  sum(length(arrayFilter(i -> a[i].2='pause'  AND a[i+1].2='pause',  range(1, length(a))))) AS pause_pause
FROM per;
```

```
 resume → resume  consecutive     9,958      ← a resume that resumes nothing
 pause  → pause   consecutive       560
 sessions whose FIRST pause/resume event is a resume     900
 pauses with no later resume at all    6,124  (22.4%), across 5,858 sessions
```

A clean toggle cannot produce 9,958 double-resumes. `resume` is evidently also emitted after seeks,
buffering recovery, and app foregrounding — all of which are represented separately elsewhere in the
same 41-value `event` vocabulary (`Seek` 32,036, `BufferEnd` 66,289, `AppForegrounded` 14,321).

### 3 · How this breaks the shipped rule

`sql/30_build_intervals.sql` computes, for every pause `p`:

```sql
arrayFirst(x -> x > p, resumes)     -- the FIRST resume after the pause closes the window
```

```
 real timeline
   pause ──────────────────────────────────────────── resume (the real one)
    t=100                                                t=500
              ▲ resume (spurious — fired by a buffer recovery)
                t=150

   shipped rule excludes  [100 → 150)  =  50 s of paused time
   truth is               [100 → 500)  = 400 s

   → 350 s silently booked as WATCH TIME
```

Note the direction: our rule is labelled **conservative**, and it *is* conservative about pauses that
never resume. But on pauses that *do* resume it is accidentally **permissive** — it credits watch time
we cannot prove.

### 4 · The size of it, measured end to end

Both readings run over the whole file:

- **Rule A (shipped):** a pause closes at the *first* resume after it.
- **Rule B:** a pause closes at the *last* resume before the *next pause* — i.e. a burst of resumes is
  treated as one un-pause event.

```sql
WITH per AS (
  SELECT video_session_id,
    arraySort(groupArrayIf(toInt64(event_timestamp), event='pause'))  AS ps,
    arraySort(groupArrayIf(toInt64(event_timestamp), event='resume')) AS rs
  FROM csv_audit.raw_str WHERE event IN ('pause','resume') GROUP BY video_session_id)
-- Rule A: arrayFirst(r -> r > p, rs)
-- Rule B: arrayMax(arrayFilter(r -> r > ps[i] AND (i = length(ps) OR r < ps[i+1]), rs))
```

| | windows | paused time counted |
|---|---|---|
| **Rule A — shipped** | 21,216 | **816.1 h** |
| **Rule B — burst reading** | 20,921 | **1,005.2 h** |
| **difference** | | **189.2 h** |

Against 1,949.3 h of counted watch time, that is **9.7%** — and it moves in the direction of *less*
watch time, i.e. we are currently over-counting if Rule B is what the answer key did.

For scale, the two open pause questions side by side:

```
 unclosed-pause rule  (ADR 0007, TODOS H2a)      99.3 h    5.09%   ← "largest unresolved"
 resume semantics     (this file)               189.2 h    9.7%    ← actually the largest
```

### 5 · Look-alikes that must not be matched loosely

The vocabulary contains `AdPause` (45), `AdResume` (27), `speed-pause` (380), `speed-resume` (380),
`download_resumed` (4) — **836 rows**. Our model matches `event = 'pause'` and `event = 'resume'`
exactly, so we are safe today; a case-insensitive or `LIKE '%pause%'` refactor would silently capture
all of them.

---

## Exactly what to ask

> "In the file you shipped there are 27,340 `pause` events and 31,780 `resume` events — 4,440 more
> resumes than pauses. When we order each session's pause/resume events by time, we find **9,958
> cases of a resume immediately following another resume**, and **900 sessions whose very first
> pause-or-resume event is a resume**, with no pause anywhere before it. So `resume` clearly fires for
> more than just un-pausing — it looks like it also fires after seeks, buffering recovery, or
> foregrounding.
>
> **The question:** when a viewer pauses, what ends the paused period under judge spot-check semantics? Is it the
> very next `resume` event, or does the model require the resume to actually correspond to that pause —
> and if so, how does it tell them apart?
>
> We ask because we measured both readings end to end. Closing at the first resume gives us 816 hours
> of paused time; treating a burst of resumes as one un-pause gives 1,005 hours. **That's 189 hours —
> nearly 10% of the watch time we report.** It's a bigger open question for us than the unclosed-pause
> rule.
>
> **And a smaller one while we're here:** is a `resume` with no preceding `pause` meaningful — does it
> imply there was an *unlogged* pause we should be excluding — or is it safe to ignore?"

---

## Why this is worth mentor time

It is the **largest single unresolved number in the model**, and it is unfittable from the data. There
is no ground-truth signal in the file that says which resume was the "real" one — both readings are
internally consistent, both produce a plausible curve, and the difference does not show up as an error
anywhere in our own reconcile gate (which recomputes truth from `ev_raw` using *the same rule*, so it
agrees with itself by construction).

That last point is the dangerous part: **`/reconcile` cannot catch this.** Our gate proves the serving
layer matches our interval derivation. It does not prove our interval derivation matches the
organiser's definition. A 9.7% definitional error passes every test we have.

The sub-question about unpaired resumes matters too: if an unpaired `resume` implies an *unlogged*
pause, then there is inactive time we are currently crediting as watched and it is completely
invisible to us — 900 sessions begin that way.

## How the answer changes what we build

| If they say | We change | Cost | Effect on the headline |
|---|---|---|---|
| **"first resume ends it"** | nothing — Rule A is already shipped | zero | 1,949.3 h stands |
| **"a burst of resumes is one un-pause"** | change `arrayFirst` → `arrayMax` bounded by the next pause, in `sql/30_build_intervals.sql` *and* the independent re-implementation in `sql/90_reconcile.sql` | ~6 lines in two files + rebuild + reconcile | watch time drops ~189 h → **~1,760 h** |
| **"resume must pair to a pause; unpaired resumes are ignored"** | collapse consecutive same-state events to one before pairing (repeated resume = no-op, repeated pause = one pause) | one `arrayFilter` in the fold | between the two above; needs re-measuring |
| **"an unpaired resume implies an unlogged pause"** | new exclusion rule — 900 sessions open with one; scope unknown until measured | new derivation branch, ADR required | unknown, potentially large |
| *no answer received* | keep Rule A, and **report the 189 h sensitivity in the deck** next to the unclosed-pause 99.3 h — "here are the two definitional forks and what each costs" | zero | turns the biggest silent risk into a defended trade-off |

**Regardless of the answer**, one thing should change: this belongs in the tail-sensitivity sweep
(TODOS H8) alongside `GAP_S` and `TAIL_S`, so the deck can show the full envelope of defensible
answers rather than a single number presented as certainty.

## Our current assumption

Rule A — a pause closes at the first `resume` after it. Unpaired resumes are noise and are ignored.
**Both halves of that assumption are now known to be load-bearing rather than safe.**

## Answer

**ANSWERED — mentor, 2026-08-02, relayed by the operator.**

> *"The 'more resume thing', or the irregular thing in the data — that's understandable and valid.
> That's a part in large PB-scale datasets."*

### What it settles

The excess and unpaired resumes are **real signal, not a data-quality defect**. At petabyte scale
this shape is expected: retries, multi-source emitters, client reconnects and at-least-once delivery
all produce it. So the question we should *stop* asking is "which of these resumes is spurious" —
none of them are, in the sense of being corrupt.

**This closes the option we were most tempted by and would have been wrong to take.** The fourth row
of the decision table — *"an unpaired resume implies an unlogged pause"* — treated the irregularity
as evidence of missing data and would have invented an exclusion rule to compensate. That is now
explicitly ruled out. The irregularity is the data being itself, not the data being broken.

It also removes any case for "cleaning" resumes in preprocessing. `sql/15_normalise.sql` and
[ADR 0025](../docs/adr/0025-hostile-input-quarantine-over-rejection.md) must **not** collapse,
deduplicate or repair resume sequences — they are legitimate input. Quarantine is for malformed
rows; an unpaired resume is not malformed.

### What it does NOT settle

The mentor confirmed the data's **validity**, not the **semantics** of the pause window. Rows 1–3 of
the decision table are still live: does a pause close at the *first* resume after it (shipped Rule A),
at the *last* of a consecutive burst, or only when a resume can be paired to it? The **189.2 h /
9.7%** sensitivity between those readings is unchanged and still ours to defend.

Our position, now on firmer ground: **Rule A stands.** Given that repeated resumes are a normal
artifact of at-least-once delivery rather than distinct user actions, treating the first as the
un-pause and the rest as redundant restatements of the same event is the reading most consistent
with what the mentor described. We keep it, and we keep reporting the 9.7% envelope beside it.

### Consequences applied

- Decision-table row 4 struck as ruled out.
- Preprocessing must not repair resume sequences — noted here and to be reflected in ADR 0025.
- The 9.7% sensitivity stays in `SUBMISSION.md`'s open-questions list, re-scoped from "we may be
  wrong about the data" to "this is a definitional choice we made, and here is its cost".
