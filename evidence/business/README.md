# evidence/business/ — every number in docs/BUSINESS_RULES.md, measured live

> **Summary:** All figures behind [docs/BUSINESS_RULES.md](../../docs/BUSINESS_RULES.md), re-measured
> **read-only against the graded `sonyliv` database on 2026-08-02** after the rebuild that closed the
> promotion incident. Confirms the headline (1,978.1 h / 2,976.9 h / 33.6%; peak 2,917 vs naive 3,708,
> gap 791) and adds three things nobody had measured: a **waterfall** decomposing the 998.8 excluded
> hours into 862.2 h of silence and 382.8 h of pause against +246.2 h of tail credit; the fact that
> **0 of 10,866 sessions are still open**, so the live-dashboard path is unexercised by the graded file;
> and an **18.2% grain split** — the pipeline reports 1,978.1 h at second grain and 2,338.4 h at the
> minute grain its own serving layer uses for "average concurrency".

**Measured:** 2026-08-02 · ClickHouse Cloud 26.2.1.525 · database `sonyliv` · **reads only** — no
INSERT/ALTER/TRUNCATE/OPTIMIZE was issued, `REBUILD_GRADED` and `APPLY_GRADED_DESTRUCTIVE` never set.
Serving state at measurement time: `ev_raw` 905,558 · `session_intervals` 30,323 · `cc_minute_delta`
28,073.

> ⚠️ **Why these were re-measured rather than cited.** The committed `evidence/reconcile.txt` is the
> **failing** gate run from the 2026-08-02 corruption incident (970 of 17,028 minutes mismatched,
> `session_aware_hours: 1760.2`) — it was deliberately committed as the record of the failure, per
> `c14ec21`, and has not been regenerated since the rebuild. Quoting its `1760.2` would have been
> wrong. The live database now reproduces the documented 1,978.1 h exactly.

---

## 1 · Headline, re-verified live

```sql
SELECT
  round((SELECT sum(dateDiff('second', interval_start, interval_end)) FROM session_intervals FINAL)/3600,1) AS session_aware_hours,
  round((SELECT sum(sp) FROM (SELECT dateDiff('second', min(event_timestamp), max(event_timestamp)) AS sp
                              FROM ev_raw GROUP BY video_session_id))/3600,1) AS naive_span_hours,
  round(100 - 100*session_aware_hours/naive_span_hours, 1) AS pct_excluded;
```

```
session_aware_hours: 1978.1
naive_span_hours:    2976.9
pct_excluded:        33.6
intervals:           30323
deltas:              28073
```

Peak, and the naive count at the same minute:

```
session_aware_peak: 2917       peak_minute: 2026-07-26 10:56:00
naive_session_span: 3708
gap:                 791
pct_overcount:      21.3
user_tier_peak:     2844
```

All five match the figures the repo already carries. **The brief's numbers are good.**

### 1a · The gate, re-run read-only

`sql/90_reconcile.sql` is a pure `SELECT` (no INSERT/CREATE/ALTER anywhere in it), so it can be run
against the graded database without writing anything. Run directly rather than through
`tools/reconcile.sh`, because that script overwrites `evidence/reconcile.txt`, which this task does
not own:

```bash
curl -sS "https://${CH_HOST}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
  --user "${CH_USER}:${CH_PASSWORD}" --data-binary "@sql/90_reconcile.sql"
```

```
ord  scope     c1                        c2             c3               c4          verdict
  0  SUMMARY   minutes_compared=17028    mismatched=0   max_abs_diff=0   peak=2917   PASS
  2  sample    2026-07-14 15:43:00       1              1                0           PASS
  2  sample    2026-07-16 12:35:00       0              0                0           PASS
  2  sample    2026-07-17 08:56:00       0              0                0           PASS
  2  sample    2026-07-26 10:56:00       2917           2917             0           PASS
  2  sample    2026-07-26 11:30:00       197            197              0           PASS
```

**The gate is green on the live graded database as of 2026-08-02** — every one of the 17,028 minutes,
idle minutes included, 0 mismatched, `max_abs_diff` 0. This was verified here rather than cited,
because the only committed record of a green run is prose in `docs/PROMOTION.md`; the committed
`evidence/reconcile.txt` still holds the failing run.

---

## 2 · The waterfall — where the 998.8 excluded hours go

Nobody had decomposed the gap. This does, and it reconciles to the live total **exactly**.

| Step | Hours | What it is |
|---|---:|---|
| Naive session span | 2,976.9 | first event to last event, per session |
| − silence gaps > 150 s | −862.2 | backgrounded or gone — heartbeats stopped |
| = run span | 2,114.7 | |
| + tail credit (60 s × **8,978** segments) | +149.6 | one cadence credited past a run's last event |
| − pause windows inside runs | −286.2 | explicit `pause`→`resume`, net of silence already excluded |
| **= counted watch time** | **1,978.1** | ✓ matches the live table exactly |

**The tail row required care and a first attempt got it wrong.** Not every run pays a tail: tail is
credited only to a segment that ends *at the run's end*, and a run whose last pause never resumes has
its final segment end at that **pause**, not at the run end. Measured, **5,699 of the 14,772
non-zero-span runs end inside an unclosed pause and receive no tail at all** — so a naive
`60 s × 14,772` over-states tail credit by 96.6 h (246.2 h against a true 149.6 h) and pushes the
error into the pause row.

The corrected figures come from replicating the whole derivation from `ev_raw` — runs, pause windows,
the `arrayFold` complement, and the conditional tail — and summing it:

```sql
WITH 150 AS GAP_S, 60 AS TAIL_S,
per_session AS (
  SELECT video_session_id,
    arraySort(groupArray(toUnixTimestamp(event_timestamp))) AS ts,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event='pause'))  AS pauses,
    arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event='resume')) AS resumes
  FROM ev_raw GROUP BY video_session_id),
runs AS (
  SELECT video_session_id, pauses, resumes,
    arrayJoin(arraySplit((t,i) -> (i>1) AND ((t-ts[i-1])>GAP_S), ts, arrayEnumerate(ts))) AS run
  FROM per_session),
windowed AS (
  SELECT run[1] AS run_start, run[length(run)] AS run_end,
    arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
      p -> (p, least(if(arrayFirst(x -> x >= p, resumes) = 0, run_end,
                        arrayFirst(x -> x >= p, resumes)), run_end)),
      arrayFilter(p -> (p >= run[1]) AND (p < run[length(run)]), pauses)))) AS pause_windows
  FROM runs),
folded AS (
  SELECT *, arrayFold((acc, win) -> (if(win.1 > acc.2, arrayPushBack(acc.1, (acc.2, win.1)), acc.1),
                                     greatest(acc.2, win.2)),
    pause_windows, (CAST([], 'Array(Tuple(UInt32, UInt32))'), toUInt32(run_start))) AS fold
  FROM windowed)
SELECT round(sum(seg.2 - seg.1 + if(seg.2 = run_end, TAIL_S, 0))/3600, 1) AS reconstructed_hours,
       countIf(seg.2 = run_end) AS runs_paying_tail
FROM folded
ARRAY JOIN arrayFilter(x -> x.2 > x.1, arrayPushBack(fold.1, (fold.2, toUInt32(run_end)))) AS seg;
```

```
reconstructed_hours: 1978.1     ← reproduces the live table exactly
runs_paying_tail:      8978     → 149.6 h of tail credit
```

**This is a fourth independent reproduction of the headline** (after the SQL model, the reconcile
gate, and `tools/reference_interpreter.py`), and it validates the decomposition rather than just the
total. Two independent confirmations fall out of it:

- The residual pause exclusion, **286.2 h**, matches to the decimal a figure already written in
  `sql/30_build_intervals.sql`'s own comment block — *"the model actually over-excluded 309.5 h → 286.2 h"*
  for the inclusive `>=` resume rule. The decomposition was derived without reference to that comment.
- The **net** pause exclusion is 286.2 h, not the 816.1 h of raw pause windows
  [doubts/02](../../doubts/02-resume-semantics.md) measures — most paused time overlaps silence the
  gap rule had already removed, exactly as ADR 0007 predicted for the unclosed-pause question.

Commercially, the number to carry away: **7.6% of everything we count (149.6 h) is tail credit** —
grace after the last observed event, not observed watching — and **38.6% of runs forfeit even that**
because they end inside a pause that never resumed.

---

## 3 · The inclusion ledger, measured

```sql
-- runs, and what terminates them (final-second-contains, not last-tuple:
-- a tuple sort tie-breaks on the event string and gives the wrong answer)
WITH per_session AS (
  SELECT video_session_id,
         arraySort(groupArray((toUnixTimestamp(event_timestamp), event, event_type))) AS te
  FROM ev_raw GROUP BY video_session_id),
runs AS (
  SELECT arrayJoin(arraySplit((x,i) -> (i>1) AND ((x.1 - te[i-1].1) > 150), te, arrayEnumerate(te))) AS run
  FROM per_session),
lastsec AS (
  SELECT run[1] AS run_start, run[length(run)].1 AS run_end,
         arrayFilter(x -> x.1 = run[length(run)].1, run) AS final_second_events
  FROM runs)
SELECT count(),
       countIf(arrayExists(x -> x.3 = 'VideoSessionEnd', final_second_events)),
       countIf(arrayExists(x -> x.2 = 'pause',           final_second_events)),
       countIf(arrayExists(x -> x.3 = 'AppBackgrounded', final_second_events))
FROM lastsec;
```

```
total runs                                14,954
final second contains VideoSessionEnd     10,758   (71.9%)   ← reproduces doubts/07 exactly
final second contains pause                2,898             ← reproduces doubts/07 exactly
final second contains AppBackgrounded      3,634
zero-span runs (dropped entirely)            182   (175 sessions)
  … of which literally one event              75
sessions with NO VideoSessionEnd               0   ← the is_open population is EMPTY
sessions emitting events after their end     239   (2.2%)
```

**The 182 is a zero-*span* count, not a lone-*event* count.** A first pass measuring
`length(run)=1` returns **75**; the other 107 are runs of several events that all land inside one
truncated second, so `run_start = run_end` and `arrayFilter(x -> x.2 > x.1, …)` drops them too. Total
runs (14,954) matches the property suite; the drop condition is the span, not the event count.

**`is_open` is empty on the graded file.** All 10,866 sessions carry a `VideoSessionEnd`, so no
interval is ever marked open. The still-watching path — the one a live dashboard depends on — is
exercised by **zero rows** of the graded data.

Ad-break vocabulary, and what the pause rule does and does not match:

```
event            events  sessions  treatment
pause            27,340    10,669  MATCHED by the pause rule
resume           31,780     8,826  MATCHED by the pause rule
AdSkipTrueView    1,889     1,229  not matched — counts as watching
speed-pause         380       174  not matched — counts as watching
speed-resume        380       174  not matched — counts as watching
AdBufferStart        83        42  not matched — counts as watching
AdBufferEnd          62        36  not matched — counts as watching
AdPause              45        27  not matched — counts as watching
AdResume             27        19  not matched — counts as watching
AdClick               4         4  not matched — counts as watching
```

Ad breaks count as watching, which is correct — the break *is* the inventory. But it is correct by
**exact lowercase string match**, so a vocabulary change on the unseen day breaks it silently. That
is the same exposure [doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md) prices.

---

## 4 · The grain split — 1,978.1 h and 2,338.4 h are both ours

Three ways to ask "how many hours were watched", all against the same live tables:

```sql
-- (a) exact interval seconds — what /reconcile headlines
SELECT sum(dateDiff('second', interval_start, interval_end))/3600 FROM session_intervals FINAL;
-- (b) session-minutes x 60, deduped by session
SELECT count()*60/3600 FROM (SELECT DISTINCT video_session_id,
  arrayJoin(range(intDiv(toUnixTimestamp(interval_start),60)*60,
                  intDiv(toUnixTimestamp(interval_end),60)*60 + 1, 60)) AS m
  FROM session_intervals FINAL);
-- (c) the hour cube's stored integral, which is what the serving layer returns
SELECT sum(integral)/3600 FROM cc_hour_agg FINAL WHERE cube_level = 0;
```

| Measure | Hours | Used by |
|---|---:|---|
| (a) exact interval seconds | **1,978.1** | the headline, the 33.6%, the deck |
| (b) session-minutes × 60, deduped | **2,338.4** | — |
| (c) hour-cube `integral` | **2,338.4** | **`avg_concurrent` in every benchmark answer** |

**(b) and (c) agree exactly**, which is a clean independent check on the hour cube. But they sit
**18.2% above (a)**, because any-overlap minute membership credits a session the whole minute it
touches. `evidence/benchmark/b01_day_peak_avg_total.sql` returns `integral` and
`round(avg_concurrent, 2)` — so the *average concurrency* we serve is derived from the 2,338.4 h
number while the *hours* we headline come from 1,978.1 h.

Neither is wrong; they answer different questions. But a reader who multiplies our average
concurrency by elapsed time gets 2,338.4 h, and a reader who quotes our headline gets 1,978.1 h, and
**nothing in the repo currently tells them why they differ.** This is the same any-overlap convention
[doubts/09](../../doubts/09-minute-membership-instant-reading.md) prices at −14.1% on the peak,
surfacing in the hours metric instead.

At minute grain the naive comparison is:

```
naive, minute grain      3,157.2 h
model, minute grain      2,338.4 h      over-count 25.9%
naive, second grain      2,976.9 h
model, second grain      1,978.1 h      over-count 33.6%
```

The headline 33.6% is like-for-like (both second grain) and is **sound**. But the honest range for
"how much does the naive count overstate" is **25.9%–33.6% depending on grain**, not a single number.

An interval-level expansion (not deduped by session) reads **2,481.7 h** — 143.3 h higher than (b),
because a session with two intervals inside one minute is counted twice. That is exactly the double
count `sql/40_deltas.sql` merges away by grouping on session, and it reproduces here as a
sanity check that the merge is doing its job.

---

## 5 · Peak versus average, from the hour cube

```sql
SELECT hour, peak, round(integral/3600.0, 0) AS avg_concurrency_in_hour,
       round(peak/(integral/3600.0), 2) AS peak_to_avg
FROM cc_hour_agg FINAL WHERE cube_level = 0 ORDER BY peak DESC LIMIT 3;
```

```
hour                  peak   avg_in_hour   peak_to_avg
2026-07-26 10:00      2917          1091          2.67
2026-07-26 11:00      2873           992          2.90
2026-07-26 09:00        55            42          1.31
```

**Peak is 2.67× the average within the very hour it occurs.** Provisioning on the average
under-provisions by 63% at peak; billing on the peak over-bills by 2.67×. Both are one-line mistakes
and the hour cube serves both statistics from the same row, which is precisely why the choice has to
be made deliberately.

Whole-day figures for 2026-07-26 (`cube_level = 0`): peak 2,917, `integral` = 2,210.5 viewer-hours,
day average 92.1 concurrent over the full 86,400 s. **The day average is not a usable statistic on
this file** — the data ends at 11:31, so 12.5 hours of structural zero drag it down and the 31.7×
peak-to-day-average ratio is an artefact of a truncated day, not a property of the audience. The
in-hour ratio above is the honest one.

---

## 6 · Serving cost, cited not re-run

From [`evidence/bench.txt`](../bench.txt), tag `bench-20260801T165403Z`, ClickHouse Cloud
26.2.1.525, median of 3 timed runs with the query cache off. **`ev_raw` is never read** by any of them.

| Query | Shape | Bytes read | Server ms |
|---|---|---:|---:|
| `b01_day_peak_avg_total` | day peak + average, no filter | 240.0 KiB | 44.5 |
| `b05_hour_grain_peak_day` | hour grain across a day | 336.0 KiB | 12.2 |
| `b06_minute_series_peak_hour` | minute series, one hour | 312.0 KiB | 7.5 |
| `b07_minute_series_peak_hour_platform` | minute series, platform filter | 208.0 KiB | 7.0 |
| `b13_hour_top_content` | top-10 titles in an hour | 272.0 KiB | 14.3 |

⚠️ These were measured on 2026-08-01, one day before this capture, and are **not** re-run here —
re-running the benchmark writes evidence files owned by another task. The serving state matches
(`ev_raw` 905,558 / `session_intervals` 30,323 / `cc_minute_delta` 28,073 in both), so the shapes are
comparable.

---

## 7 · What is cited from elsewhere, and not re-derived

These would each need a full rebuild in a scratch database to reproduce, which is out of scope for a
read-only measurement pass. Each is carried with its source.

| Figure | Effect on peak | Source |
|---|---|---|
| Instant-sampling minute membership | 2,917 → 2,507 (**−14.1%**) | [doubts/09](../../doubts/09-minute-membership-instant-reading.md) |
| Fail-closed foreground+playing gates | 2,917 → 2,606 (−10.7%), 1,978.1 → 1,720.3 h | [doubts/10](../../doubts/10-fail-closed-state-gates.md) |
| Burst-resume pause reading (Rule B) | 816.1 h → 1,005.2 h paused (**9.7%** of hours) | [doubts/02](../../doubts/02-resume-semantics.md) — validity answered 2026-08-02, semantics still open |
| Suppress tail at explicit stops | 2,917 → 2,776 (−4.8%), −7.1% hours | [doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md) |
| Allow-list liveness (heartbeat + play only) | 2,917 → 2,880 (−1.3%) | [doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md) |
| Keep point activity (the 182 zero-span runs) | 2,917 → **2,927** (+0.34%), +5.0 h | [evidence/property](../property/README.md) |
| Permissive unclosed-pause rule | +4.5% peak, +99.3 h | ADR 0007 — ⚠️ measured pre-ADR-0009, **stale** |
