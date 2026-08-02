# 08 · Second-truncation inverts pause/resume order — ADR 0009's `>=` closes pauses with resumes that happened first

> **Summary:** The whole pipeline truncates `event_timestamp` (DateTime64(3)) to whole seconds. ADR
> 0009 then made the pause-closure lookup `>=` so a same-second resume can close its pause — but of
> the **2,697** same-second pause/resume ties, **1,781 (66%)** have the resume **milliseconds
> *before* the pause**: in true event order those resumes precede the pause and close nothing, and
> the pause should fall through to the unclosed-pause rule. A full millisecond-precision rebuild
> (same derivation, ×1000 constants) moves the headline **2,917 → 2,865 (−52, −1.8%) and 1,978.1 →
> 1,926.0 h (−2.6%)**. Model and gate truncate identically, so 17,028 green minutes carry no
> evidence on this. Challenges [ADR 0009](../docs/adr/0009-same-second-resume-and-deterministic-attribution.md);
> sibling of [doubts/02](02-resume-semantics.md) (which asks what a resume *means*; this asks *when it is*).

**Status:** open · **Evidence measured:** 2026-08-01, local scratch `adv_q19` rebuilt verbatim from
`sql/30_build_intervals.sql` (baseline reproduces the graded 2,917 / 1,978.1 h exactly)

---

## The evidence

### 1 · Two-thirds of the same-second ties are order-inverted

```sql
WITH per AS (
  SELECT video_session_id,
         arraySort(groupArrayIf(toUnixTimestamp64Milli(event_timestamp), event = 'pause'))  AS pms,
         arraySort(groupArrayIf(toUnixTimestamp64Milli(event_timestamp), event = 'resume')) AS rms
  FROM ev_raw GROUP BY video_session_id)
SELECT
  sum(length(pms))                                                             AS pauses,
  sum(length(arrayFilter(p -> arrayExists(r -> intDiv(r,1000) = intDiv(p,1000), rms), pms)))
                                                                               AS same_second_ties,
  sum(length(arrayFilter(p -> arrayExists(r -> intDiv(r,1000) = intDiv(p,1000) AND r < p, rms)
                          AND NOT arrayExists(r -> r >= p AND intDiv(r,1000) = intDiv(p,1000), rms),
                         pms)))                                                AS resume_actually_before,
  sum(length(arrayFilter(p -> arrayFirstIndex(r -> r >= p, rms) = 0
                          AND arrayExists(r -> intDiv(r,1000) = intDiv(p,1000), rms), pms)))
                                                                               AS s_closed_ms_unclosed
FROM per;
```

```
 pauses                                            27,340
 same-second pause/resume ties (ADR 0009's case)    2,697
 …where the resume is ms-BEFORE the pause           1,781   (66% of the ties)
 …s-closed but fully UNCLOSED at ms precision         179
```

ADR 0009 reasoned: "a strict `>` cannot see a resume that lands in the same truncated second as its
pause" and shipped `>=`, treating the tie as pause-instantly-resumed (zero-length window, dropped —
the pause vanishes). At millisecond precision the majority of those resumes **precede** their pause:
the seek/buffer burst emitted `resume` first, then `pause`. A resume that happened before the pause
cannot close it. For 1,781 pauses the truncation doesn't just blur the window — it deletes a pause
that, in true order, is open until the next later resume, or unclosed (179 of them have **no** later
resume at all and go to the conservative to-run-end rule).

### 2 · The delta, measured end to end

Full rebuild with the shipped derivation at millisecond precision — the only changes are
`toUnixTimestamp` → `toUnixTimestamp64Milli` (everywhere, including run splitting), `GAP_S`/`TAIL_S`
×1000, fold tuples widened to `Int64`, and `fromUnixTimestamp64Milli` in the projection (recipe in
[evidence/adversarial/README.md](../evidence/adversarial/README.md)):

```
                        intervals   hours              peak
 seconds (shipped)      30,323      1,978.1            2,917
 milliseconds           32,925      1,926.0 (−2.6%)    2,865 (−52, −1.8%)
```

Same peak minute, 2026-07-26 10:56. Run splitting is a negligible part of the movement — 4,096
ms-gaps > 150 s vs 4,088 s-gaps (8 runs differ); the movement is the pause windows.

### 3 · Why the gate is blind here

`90_reconcile.sql` truncates with `toUInt32(event_timestamp)` and carries the identical `>=` lookup
(its own comment concedes: *"an independent implementation of a wrong DEFINITION proves nothing"*).
Both sides see the same already-truncated instants; the information that distinguishes the readings
was destroyed before either side runs.

## Exactly what to ask

> "Will judge spot-checks use millisecond precision or second-truncated timestamps? In
> particular, when a `resume` and a `pause` share the same second but the resume's milliseconds come
> first, does that resume close the pause? 2,697 pauses hit the tie, 1,781 of them are
> order-inverted, and the two readings differ by 52 viewers (1.8%) at peak / 52.1 h (2.6%) of watch
> time."

## Why this is worth mentor time

The data ships milliseconds; we throw them away. If the answer key kept them, ADR 0009's `>=` fix —
which moved the published baseline 2,887 → 2,917 — over-corrects: it converted 2,697 ambiguous ties
into "no pause", when the ms-true reading keeps most of them paused. 52 viewers is ~2× the entire
resume-vocabulary exposure ADR 0009 measured, and it biases in the over-count direction the project
explicitly chose conservatism to avoid.

## How the answer changes what we build

| Answer | Change |
|---|---|
| Truth is second-truncated, ties resolved as instantly-resumed (our assumption) | Nothing; ADR 0009 stands as is. |
| Truth is millisecond-precise | Port the derivation to ms (recipe already validated end to end in the adversarial harness): `toUnixTimestamp64Milli` throughout `30_build_intervals.sql` **and** `90_reconcile.sql`, constants ×1000, fold tuples `Int64`. Peak 2,865. `cc_minute_delta` schema unchanged (minutes stay minutes). |
| Truth is second-truncated but ms decide within-second order | Keep seconds architecture; pause windows built from ms-ordered pause/resume pairs (close only at a resume with `r_ms >= p_ms`), then truncate windows. Between the two above; one harness run measures it. |

## Our current assumption

Second truncation everywhere; a same-second resume closes its pause regardless of sub-second order
(ADR 0009's `>=`, shipped in model and gate).

## Answer

_unrecorded_
