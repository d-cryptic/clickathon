# 09 · "Concurrent at minute M" — any overlap, or present at the instant M begins? Worth 410 viewers

> **Summary:** Our model counts a session at minute M if it was active for **any part** of M. The
> other common reading — active **at the instant M:00** (how a sampled/gauge metric reads) — gives a
> peak of **2,507 against our 2,917: −410 viewers, −14.1%**, at the same peak minute. This is the
> single largest definitional fork we have measured, dwarfing resume semantics (9.7% of hours) and
> unclosed pauses (4.6%). The gate cannot see it: `sql/90_reconcile.sql` expands truth with the same
> inclusive-minute convention the model uses, so both sides agree by construction. **Measures mentor
> Q8 in [docs/MENTOR_QUESTIONS.md](../docs/MENTOR_QUESTIONS.md), which was previously unquantified.**

> **Read with [05](05-minute-boundary-membership.md).** Both dossiers probe minute membership and
> both deepen mentor **Q8**, but they ask different halves and the stakes are nothing alike. 05 asks
> only about the **end boundary** — does an interval ending exactly at 10:56:00 belong to 10:56? —
> and moves the peak by **one viewer** (2,917 → 2,916). This one asks whether membership means *any
> overlap* or *presence at the instant*, and moves it by **410** (2,917 → 2,507). If a mentor answers
> only the narrow question, 09 stays open. **Ask this one first.**

**Status:** open · **Evidence measured:** 2026-08-01, local scratch `adv_q19` rebuilt verbatim from
`sql/30_build_intervals.sql` (baseline reproduces the graded 2,917 / 1,978.1 h exactly)

---

## The evidence

### 1 · The two readings

- **Any-overlap (shipped):** a session whose interval touches any second of minute M counts at M.
  This is what the delta layer serves (+1 at `toStartOfMinute(interval_start)`, −1 at
  `toStartOfMinute(interval_end) + 60`) and what the gate's `truth_min` recomputes
  (`range(intDiv(a,60)*60, intDiv(b,60)*60 + 1, 60)` — inclusive at both ends).
- **Instant-sampling:** a session counts at M only if `interval_start <= M:00 <= interval_end`.
  This is how a Prometheus-style gauge, or any "how many are watching *right now*" number sampled
  once a minute, would read.

### 2 · The delta, measured end to end

```sql
-- instant-sampling peak over the baseline intervals:
-- first minute boundary >= start, through last boundary <= end
WITH per_min AS (
  SELECT m, uniqExact(video_session_id) AS c
  FROM (
    SELECT video_session_id,
           arrayJoin(range(intDiv(toUnixTimestamp(interval_start) + 59, 60) * 60,
                           intDiv(toUnixTimestamp(interval_end), 60) * 60 + 1, 60)) AS m
    FROM adv_q19.si_baseline
    WHERE intDiv(toUnixTimestamp(interval_end), 60) * 60
          >= intDiv(toUnixTimestamp(interval_start) + 59, 60) * 60)
  GROUP BY m)
SELECT max(c), toDateTime(argMax(m, c)) FROM per_min;
```

```
 any-overlap (shipped)      2,917  @ 2026-07-26 10:56
 instant-sampling           2,507  @ 2026-07-26 10:56    −410 · −14.1%
```

The peak minute is identical; only the value moves. The gap is every session that starts or ends
inside the minute: at a peak with heavy churn, ~14% of the counted sessions touch the minute without
covering its opening instant.

### 3 · Why the gate goes green under either

`90_reconcile.sql` derives truth with the same inclusive expansion, so 17,028 minutes compare 0
mismatched under the shipped reading — and would also compare 0 mismatched if both sides carried the
sampling reading. A green gate carries **zero evidence** on this question; only the answer key's own
convention decides it.

### 4 · Relation to the boundary-tie dossier (doubts/05, owned elsewhere)

The minute-boundary convention (`toStartOfMinute(interval_end)` inclusion, 505 intervals, peak
2,917 → 2,916) is the **small edge** of this same family. This dossier is the **structural** fork:
−1 vs −410. An answer to this question almost certainly settles that one for free.

## Exactly what to ask

> "Is a session concurrent at minute M if it was active for **any part** of M, or only if it was
> active **at the instant M begins**? Concretely: a viewer who watches 10:56:10–10:56:50 — do they
> count toward 10:56? Our model says yes (any overlap). A sampled gauge would say no. The two
> readings differ by 14% at the peak."

## Why this is worth mentor time

It is worth **410 viewers on the graded peak** — 3× the entire unclosed-pause fork and the largest
single number attached to any open question. Both readings are defensible engineering; only the
ground-truth generator knows which one it used. If the key samples, every number we submit is
systematically ~14% high and the error is invisible to every internal check we have.

## How the answer changes what we build

| Answer | Change |
|---|---|
| Any overlap (our assumption) | Nothing. Model, gate, and serving layer already agree. |
| Instant at M:00 | Delta emission in `sql/40_deltas.sql` changes to +1 at `ceil(start/60)`, −1 at `floor(end/60)+60`, with intervals shorter than their first boundary dropped; the same edit lands in `90_reconcile.sql`'s `truth_min` (two-file change, as for every shared convention); rerun `/reconcile`. Peak becomes 2,507. |
| Something else (e.g. majority of the minute) | New expansion rule in both files; the harness in `evidence/adversarial/README.md` measures it in one run. |

## Our current assumption

Any overlap counts. Shipped everywhere; consistent across model, gate, and both serving tiers.

## Answer

_unrecorded_
