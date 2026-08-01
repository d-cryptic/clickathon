# Adversarial audit — every convention the gate cannot see, probed with a measured delta

> **Summary:** The reconcile gate recomputes truth from `ev_raw` with different code but the **same
> definitions** as the model, so a wrong convention goes green on both sides. This audit rebuilt the
> full interval derivation in a scratch DB (`adv_q19`, local — the graded `sonyliv` was only ever
> SELECTed) under **21 alternative readings** of those shared conventions and measured each against the
> headline (peak **2,917** @ 2026-07-26 10:56 · **1,978.1 h**). Three movers got dossiers: minute
> membership **−410 / −14.1%** ([doubts/09](../../doubts/09-minute-membership-instant-reading.md)), tail credit at
> explicit stops **−141 / −4.8%** ([07](../../doubts/07-tail-credit-at-explicit-stops.md)), and
> second-truncation inverting pause/resume order **−52 / −1.8%**
> ([08](../../doubts/08-second-truncation-inverts-pause-resume.md)). Ten assumptions measured **safe**
> at ≤0.1% each. The peak **minute** (10:56) never moved under any variant — only the value does.

**Measured:** 2026-08-01 · local ClickHouse (`default.ev_raw`, 905,558 rows — same count as
`sonyliv.ev_raw`, verified read-only) · baseline rebuilt from `sql/30_build_intervals.sql` verbatim
and reproducing the graded numbers exactly: 30,323 intervals · 1,978.1 h · peak 2,917 @ 10:56.

---

## Method

Every probe follows the brief's shape: state the assumption, build the **smallest input that
distinguishes** the two readings (or the count of rows that hit it), run **both** readings, report the
delta on the headline. The harness:

1. `sql/30_build_intervals.sql` is templated (sed: `INSERT INTO adv_q19.si_<variant>`,
   `FROM default.ev_raw`) — the *shipped* derivation, byte-for-byte except the stated change.
2. Each variant lands in its own `adv_q19.si_<variant>` table (plain MergeTree, fresh insert).
3. Headline metrics per variant, computed with **the gate's own expansion semantics**
   (`90_reconcile.sql` `truth_min` — inclusive minute range, `uniqExact(video_session_id)`):

```sql
-- hours (identical to tools/reconcile.sh §3)
SELECT count(), round(sum(dateDiff('second', interval_start, interval_end))/3600, 1)
FROM adv_q19.si_<v>;
-- peak
WITH per_min AS (
  SELECT m, uniqExact(video_session_id) AS c
  FROM (SELECT video_session_id,
               arrayJoin(range(intDiv(toUnixTimestamp(interval_start),60)*60,
                               intDiv(toUnixTimestamp(interval_end),60)*60 + 1, 60)) AS m
        FROM adv_q19.si_<v>)
  GROUP BY m)
SELECT max(c), toDateTime(argMax(m, c)) FROM per_min;
```

Baseline validation: this harness reproduces **2,917 / 1,978.1 h / 30,323 intervals** exactly, so
every delta below is attributable to the stated change alone.

---

## The ledger — every assumption probed, ranked by how much the answer moves

Baseline: peak **2,917**, hours **1,978.1**. Δ% against those.

| # | Assumption (shipped reading) | Alternative reading | Distinguishing input | Peak | Hours | Verdict |
|---|---|---|---|---|---|---|
| 1 | Minute membership: active for **any part** of minute M counts at M | active at the **instant** M:00 | every interval not aligned to :00 | **2,507 (−14.1%)** | n/a | **mentor ruling — [doubts/09](../../doubts/09-minute-membership-instant-reading.md)** (measures mentor Q8) |
| 2 | 60 s tail grace after **every** run end | no tail where the run ends at an explicit stop (`VideoSessionEnd` or trailing `pause`) | 10,758 runs end at an end event; 2,898 at a pause | **2,776 (−4.8%)** | **1,837.2 (−7.1%)** | **probably wrong (pause half) / mentor (end half) — [doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md)** |
| 3 | Unclosed pause → paused to run end (conservative) | permissive: paused to next event | 6,124 unclosed pauses | 3,036 (+4.1%) | 2,070.0 (+4.6%) | known fork (Q2/ADR 0007) — **numbers refreshed post-ADR 0009**; ADR/skill still cite 3,018 / 2,048.6 |
| 4 | `TAIL_S = 60` ("one cadence") | 40 s = one cadence at the **measured** 40 s beat (doubts/01) | every run end | 2,872 (−1.5%) | 1,928.2 (−2.5%) | folded into [doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md); slope ≈ **2.4 viewers per tail-second** (sweep 0→120 s: 2,758→3,047) |
| 5 | Timestamps truncated to whole seconds | millisecond-precise processing | 1,781 same-second pause/resume pairs whose true order is **resume before pause** | 2,865 (−1.8%) | 1,926.0 (−2.6%) | **mentor / probably wrong — [doubts/08](../../doubts/08-second-truncation-inverts-pause-resume.md)** (attacks ADR 0009's `>=`) |
| 6 | `GAP_S = 150` | sweep 60–300 s | 4,088 gaps > 150 s | 2,964…2,897 | 2,005.2…1,972.2 | **safe-ish**: flat near shipped value (120 s: +2, 180 s: −8, ≤0.3%); steepens only below ~90 s. Sensitivity now quantified for doubts/01 |
| 7 | Concurrency counts **sessions** | distinct **users** | one user, two devices | 2,844 (−2.5%) | — | known fork (mentor Q4), now measured; matches the served user tier exactly |
| 8 | Active time starts at the session's first event | clip at first `VideoPlay` (pre-play buffering/UI excluded) | all 10,866 sessions have a `VideoPlay` | 2,898 (−0.65%) | 1,954.5 (−1.2%) | **safe** — statement excludes only backgrounded/paused/heartbeat-missing time; pre-play is none of those. Noted for completeness |
| 9 | `event = 'pause'`/`'resume'` matched exactly | also match `AdPause`/`AdResume` (45/27 events), `speed-pause`/`speed-resume` (380/380) | those 832 events | 2,918 (+0.03%) | 1,978.3 (+0.01%) | **safe** — measured immaterial |
| 10 | Gap comparison strict `>` GAP_S | `>=` | 15 gaps of exactly 150 s (52 within ±1 s) | 2,917 (0) | 1,978.2 (+0.005%) | **safe** — measured |
| 11 | `uniqExact` everywhere a distinct count serves | `uniq` (HLL) | all 3,732 minutes of the file | 0 differing minutes, max err 0 | — | **safe on this file** at this cardinality; keep `uniqExact` (ADR 0005) since HLL error is scale-dependent |
| 12 | Two intervals that touch exactly | (would double-count if mishandled) | **0** abutting and 0 overlapping pairs exist in the shipped derivation | — | — | **safe by measurement** — the zero-length-window split is dropped in `30_build_intervals.sql` (in-file measurement: with the split, 31,938 intervals, same 2,917 peak); expansion `uniqExact` dedups regardless |
| 13 | Tail may extend past the data boundary | clip at `max(event_timestamp)` | 184 intervals, 1.52 h (0.08%) | peak unaffected (mid-data) | −1.52 | **safe** — already disclosed in `evidence/reconcile.txt` |
| 14 | Events after `VideoSessionEnd` count as activity | discard post-end events | 36 whole intervals after the last end event, 1.63 h (0.08%) — the other 128.1 h "past end" is the tail credit, i.e. finding #2 | — | −1.63 | **safe** as a separate concern; subsumed by #2 |
| 15 | Open sessions absorbed by rebuild | — | **0** `is_open` intervals on this file (every session has a `VideoSessionEnd`) | — | — | **untestable on this file** — the open-session path only exercises on the unseen day. Risk noted in `RUNBOOK_UNSEEN.md` territory, not a delta |
| 16 | Serving views partition running sums by `toStartOfHour(minute)` (server-TZ-dependent) | explicit `'UTC'` | any server whose TZ has a non-whole-hour offset | **5,667 (+94%)** under `Asia/Kolkata` partitioning | — | **safe today** — both servers verified `UTC`; the gate's truth side is epoch-based so it would catch the break. Latent portability trap: recommend an explicit `'UTC'` argument (owner: serving-view files, not this audit) |
| 17 | Dominant-value dimension attribution | any per-interval attribution rule | dims are labels; the unfiltered count never reads them | 0 (structural) | 0 | **safe for the headline** by construction; filtered-query exposure is ADR 0008/0009's measured territory (73.5% of peak sessions mislabelled under `any()`) |
| 18 | Model keeps duplicate timestamps in `ts`; gate DISTINCTs them | — | duplicate (session, second) events | 0 (structural) | 0 | **safe** — a duplicate second yields a 0 gap, splits nothing, and moves no `arrayFirst` lookup; both sides provably identical on the set of instants |

Rows 1–5 are the findings. Rows 6–18 are the ruled-out list — each with the input that would have
distinguished it and the measured (or structural) zero.

Cross-cutting observation: **no variant moved the peak minute off 2026-07-26 10:56.** The peak's
location is convention-proof on this file; its value is not.

Why #6 runs the "wrong" way (a *smaller* gap threshold *raises* the count): shorter runs give
unclosed pauses (conservative rule, #3) less run to eat, and every extra split mints another 60 s
tail (#2/#4). The constants interact; they are not independently tunable.

---

## Reproduction

Harness (scratch-DB pattern per `sql/70_truncation_test.sql`; graded DB read-only throughout):

```bash
# baseline — must print 30323 · 1978.1 · 2917 · 2026-07-26 10:56:00 before any probe is trusted
V=baseline; tools/ch "CREATE DATABASE IF NOT EXISTS adv_q19"
tools/ch "CREATE TABLE adv_q19.si_${V} (…13 cols as sql/10_intervals.sql…) ENGINE=MergeTree ORDER BY (video_session_id, interval_start)"
sed -e "s/INSERT INTO session_intervals/INSERT INTO adv_q19.si_${V}/" \
    -e "s/FROM ev_raw/FROM default.ev_raw/" sql/30_build_intervals.sql | tools/ch "$(cat)"
```

Variant recipes (each applied to the templated baseline SQL):

- **#3** `s/1 AS UNCLOSED_PAUSE_TO_RUN_END/0 AS .../` · **#4** `s/60  AS TAIL_S/<n>  AS TAIL_S/` ·
  **#6** `s/150 AS GAP_S/<n> AS GAP_S/` · **#9** `s/event = 'pause'/event IN ('pause','AdPause','speed-pause')/`
  (and the resume mirror) · **#10** `s/> GAP_S/>= GAP_S/`
- **#2** add `arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event_type = 'VideoSessionEnd')) AS end_ts`
  to `per_session`, carry `end_ts` (and `pauses`) through `runs`/`windowed`, and change the tail to
  `if(seg.2 = run_end AND NOT has(end_ts, toUInt32(run_end)) AND NOT has(pauses, toUInt32(run_end)), TAIL_S, 0)`
  (drop either `has()` for the single-cause variants).
- **#5** `s/toUnixTimestamp(event_timestamp)/toUnixTimestamp64Milli(event_timestamp)/g`, constants
  ×1000, fold tuples `UInt32`→`Int64`, and `fromUnixTimestamp64Milli(toInt64(…))` in the projection.
- **#1, #7, #8, #11–14** are query-only over `adv_q19.si_baseline`; the exact SQL is in the dossiers
  and in the probe queries quoted above.
- **#16** read-only over the graded DB:
  `sum(d) OVER (PARTITION BY toStartOfHour(minute, 'Asia/Kolkata') ORDER BY minute)` vs `'UTC'` on
  `sonyliv.cc_minute_delta`; `SELECT timezone()` on both servers returned `UTC`.

Cleanup: `DROP DATABASE adv_q19` when the numbers are no longer being re-derived.

---

## Housekeeping for owners of neighbouring files (not touched by this audit, per ownership rules)

- `doubts/README.md` index needs rows for 06/07/08 (file owned by the doubts-index owner).
- ADR 0007 / `interval-math` skill still cite the **pre-ADR-0009** permissive numbers
  (3,018 / 2,048.6 h); the post-0009 measurements are 3,036 / 2,070.0 h (row 3).
- Serving views' `toStartOfHour(minute)` → `toStartOfHour(minute, 'UTC')` (row 16) is a one-line
  hardening in `sql/20_views.sql` / `70_truncation_test.sql` / `90_reconcile.sql` territory.
