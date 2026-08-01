# evidence/query-robustness — every serving shape vs data designed to break it

> **Summary:** 72 hostile-condition cases across all 13 benchmark shapes + 5 cross-shape probes,
> plus 6 arithmetic invariants checked across all 8 cube grains. Result: **the current committed
> pipeline passes every invariant on hostile data; the GRADED database currently fails all of them**
> — its three tiers disagree (hour 2917 / delta 2950 / intervals 2681 for the same day) and the
> user tier exceeds session concurrency by up to 247. Four real code holes found, all silent:
> `v_cc_window_range` misses the ADR 0022 cube pin; b13 leaks duplicate content rows; b06/b07
> accept non-aligned hours and return a plausible wrong curve; unknown filter values answer 0-rows.

Re-run everything: `tools/query-robustness.sh all` (fixture → cases → invariants). Verdict counts:
**PASS 40 · LOUD-PASS 6 · SILENT-WRONG 22 · WRONG 4** — every non-PASS is triaged below. A
`LOUD-PASS` is a hostile input that failed with an exception, which is the *desired* outcome; a
`SILENT-WRONG` answered plausibly and wrongly, which is the class a judge finds before we do.

---

## The findings that answer "plausibly but wrongly" — read these first

### F1 · The graded database is serving three mutually-inconsistent tiers (largest finding, not a shape bug)

Measured read-only on `sonyliv`, 2026-08-02, for 2026-07-26 — four answers for one day:

| source | day peak | evidence |
|---|---:|---|
| `cc_hour_agg` via `v_cc_window_range` (the committed b01 answer) | **2917** | `evidence/benchmark/results/b01_day_peak_avg_total.answer.txt` |
| `cc_minute_delta` running sum (deployed reconcile view `v_concurrency_minute_delta_total` @ 10:56) | **2950** | `results/cw09_one_minute.out` |
| `session_intervals FINAL` expansion (deployed `v_concurrency_minute_intervals` @ 10:56) | **2681** | independent truth, same number from both arithmetics |
| the repo's documented headline (committed model, local) | **2887** | `docs/ARCHITECTURE.md` |

Part `modification_time`s explain it: `cc_hour_agg` 16:39, `session_intervals` 19:18:26,
`cc_minute_delta` 19:18:28 — the tiers were written at different times from different model
generations, and `cc_minute_delta` is additive (a replayed batch doubles silently,
`docs/CONVENTIONS.md`). **The graded database would fail `/reconcile` right now** — the repo's own
gate, runnable read-only. Every `cw06–cw12` SILENT-WRONG row and every cloud invariant failure
below is this one state defect observed through a different shape; the shapes themselves faithfully
serve the inconsistent tier they read. Consequences measured here:

- `inv5`: user concurrency **exceeds** session concurrency in 643–10,048 cells per cube grain,
  max excess **247 users** (11:21: user tier 1,489 vs 1,242 sessions supported by intervals).
  The user tier is also pre-ADR-0016 (`mv_user_minute` set-union MV, cannot retract — see
  `docs/GRADED_INVENTORY.md`), so 74 user-tier minutes have *no* interval coverage at all.
- `inv1`/`inv4`: headline and per-filter day peaks disagree with interval truth at every level.
- `cw16/cw17`: peak Hindi reads 1798 raw / 2203 normalised on the deployed tier vs ADR 0011's
  measured 1768 / 2180 — same +23% raw-vs-norm gap, both inflated ~1.7% by the delta skew.

**Action this implies (not taken here — out of T5 ownership):** re-run the full model build into
`sonyliv` once, from one generation, then `/reconcile`. Until then every filtered cloud answer
carries the skew.

### F2 · `v_cc_window_range` never pins `cube_level` — the ADR 0022 hole is still open in current code

`sql/85_windows.sql:516-521` reads `cc_hour_agg` by display sentinels only. The fixture plants a
real `content_id = -1` session *and* a platform literally named `'*'`, and the hour-aligned range
10:00→11:00 then merges **three** curves whose display tuples collide on `('*','*',-1)`:

```
rollup (cube 0)               12,180 s
real content -1 (cube 4)     + 2,340 s
real platform '*' (cube 1)   +   660 s
served integral              = 15,180 s   (truth: 12,180 — avg reads 2.11 vs 1.69)
```

It also hits **every filtered level**: `wr04` (platform=ANDROID_PHONE) serves 9,180 s where truth
is 6,840 — the cube-5 row `('ANDROID_PHONE','*',-1)` for the real content −1 merges into the
platform rollup. b01–b04, b10, b11 and `wr19`'s average all inherit this. The fix ADR 0022 already
prescribes: pin `cube_level` alongside the sentinel equalities in the `whole` CTE, and thread a
`p_cube_level` into the view. `sql/50_hour_agg.sql`'s own views do this correctly (`inv4` scratch:
0 mismatches across all 8 levels) — only the window view was missed.

### F3 · b13 (top content) leaks duplicate rows and hides a real content −1

`b13` filters `platform = '*' AND country = '*' AND content_id != -1` without pinning
`cube_level`. On the fixture it returns **content 101 twice** (peak 4 from the content level, peak
1 from the platform-`'*'`+content level) — a top-10 list with a repeated key and two different
peaks (`results/ht11_top_content_unique.out`). And the real asset with `content_id = -1`
("Minus One Asset", peak 1) can never appear: `!= -1` excludes it by value. Same fix as F2.

### F4 · b06/b07 accept a non-aligned `p_hour` and return a plausible wrong curve

The dashboard-curve shapes assume `p_hour` is hour-aligned but nothing enforces it. Given
`p_hour = 10:30`, the running sum starts mid-hour with no carry-in: the shape reports **2**
where the true concurrency is **8** (`ms02`), and on the graded data 198 vs 266 (`cw19`) — every
one of the 60 minutes wrong, every one plausible. A `throwIf(toStartOfHour(p_hour) != p_hour)`
in the shape (as `v_cc_tumbling_*` already does for window widths) turns this into a loud error.

### F5 · Unknown, case-variant, and sentinel-valued filters answer "0", indistinguishable from "nobody watched"

- Window family (b01–b04, b10, b11): a platform/content that has never existed returns **one row
  of zeros** (`wr01`, `wr02`, `wr07`, `cw01`, `cw02`). There is a real difference between "nobody
  watched" and "you asked about something unknown", and this interface renders both as `0`.
- b08: an unknown or case-variant video type returns a zero row **stamped `peak_minute =
  1970-01-01 00:00:00`** (`vt02`, `vt03`, `cw13`, `cw14`) — epoch leakage a dashboard would render.
  A correct-but-empty catalog bucket (`vt04`, blank video type) produces the *identical* row, so
  the two cases cannot be told apart even in principle.
- The hour/day tier behaves **correctly**: absent hours/days serve empty (`ht01`, `ht06`, `cw21`),
  which is exactly the distinguishable behaviour the window family lacks.
- Interface domain collision (ADR 0022's lesson, applied to *parameters*): `p_platform = '*'` and
  `p_content_id = -1` mean "no filter", so a real platform `'*'` (peak 1) answers 8 (`wr03`) and
  the real content −1 (peak 1, 2,340 s) answers the rollup (`wr06`) — those values are
  **unqueryable** through the views. b07, which filters by raw equality, serves the literal `'*'`
  correctly — the same input means opposite things in two shapes (`cw18` records the cloud
  behaviour).

### F6 · ADR 0011 normalisation holds only where a query opts in — no benchmark shape does

`x02` vs `x03` on the fixture: raw `audio_language = 'hin'` sees **2** of the **4** concurrently
watching Hindi spellings; `norm_lang()` on both sides sees all 4 regardless of which spelling the
caller types (`HIN` was deliberately used as the probe). On the graded data: 1798 raw vs 2203
normalised (+22.5%). The 13 shapes filter platform/country/content where case-folding provably
merges nothing (ADR 0011 §1), so they are safe *today* — but any judge-added filter on a language
column through raw equality silently drops variants. The Devanagari spelling `हिन्दी` is **not**
merged by the subtag rule (`xd04`, peak 1, its own bucket) — visible in `v_dimension_drift`,
documented as the rule's limit, not silently folded.

### F7 · Minor, disclosed

- **Orphan content** (no catalog row): excluded from *every* `video_type` answer by b08's IN-join.
  `inv6` makes the loss a number: 1,020 s (3.09%) of fixture watch time is in no bucket; 0 orphans
  on the graded file. Disclosed, and `(unknown)` renders correctly in b13 (`ht12`).
- **`dict_content` SOURCE carries no credentials** (`sql/80_content.sql`) — loads on Cloud, fails
  `Authentication failed` on any password-protected local server. The harness overrides it in
  scratch; worth knowing before the unseen-day rehearsal runs b13 locally.

---

## What held, under conditions designed to break it

- **Range arithmetic is exact at every awkward boundary** (scratch, vs independent uniqExact
  truth): ragged 10:17→11:31 (`wr14`), mid-minute edges 10:17:30→10:44:30 (`wr15`), a 30-second
  range (`wr16`, integral exactly 8×30), one minute (`wr13`), whole-fixture span modulo F2
  (`wr18`), a session ending exactly ON an hour boundary (`wr17`), an interval dying in the last
  minute of an hour with no close leak (`ht08`/`ht09`), the middle hour of a 4-hour interval
  (`ht07`), sub-minute sessions (hour 22 = 60 s in `ht03`'s ledger).
- **Zero-concurrency ranges divide by the full window**: 12:00→14:00 answers 0/0 (`wr10`);
  day-average divides by 86,400 with quiet hours in the denominator (`ht03`: 33,000/86,400 =
  0.3819, hand-computed).
- **ADR 0014 tie-break**: hour 20's peak level is hit at 20:00 *and* 20:59 — stored
  `peak_minute` is the earliest (`ht05`).
- **IN-list semantics**: duplicates don't double count (`in02`, `cw10`†), empty list answers 0
  (`in03`, `cw11`), unknown members contribute nothing while real members answer (`in05`), a
  500-element list (every real platform + 490 fakes) equals the unfiltered day (`in06`) and a
  value that exists in exactly one hour of the range is found (`in04`).
- **Loud failures where loud is right**: inverted and zero-length ranges throw Code 395 on both
  scratch and the deployed cloud view (`wr08`/`wr09`/`cw03`/`cw04`); filtering the hour tier by a
  dimension it does not carry throws Code 47, never a silent unfiltered answer (`xd01`/`cw15`).
- **The quiet-hour curve is 60 explicit zeros**, not an empty result (`ms03`); a case-twin
  platform that genuinely exists is served exactly (`ms04`).
- **All 6 invariants PASS on scratch across all 8 cube grains** — including user ≤ session in
  every one of 3,926 (grain, minute) cells with a fixture designed to stress it (same user on two
  platforms, duplicate sessions per user), and day-peak = max-minute at all 8 levels including the
  colliding content −1 (the `cc_hour_agg`-family views pin `cube_level` correctly).

† cloud IN-list verdicts are numerically SILENT-WRONG in the matrix because *every* cloud
range-vs-truth comparison inherits F1's tier skew; the set-semantics themselves (dupes ≡ single,
huge ≡ unfiltered) hold on cloud too — shape-vs-shape, only the absolute level is off.

---

## Full matrix — shape × hostile condition

Verdicts: **PASS** = defensible answer, verified · **LOUD-PASS** = refused with an exception
(desired) · **SILENT-WRONG** = plausible wrong answer (the dangerous class) · **WRONG** = visibly
wrong (duplicate keys, known-number drift). Raw outputs per case: `results/<case>.out`
(+ `.truth` where an independent truth was computed). Conditions and expectations: `cases.tsv`.

| case | target | shape | verdict | what happened |
|---|---|---|---|---|
| `wr01_unknown_platform` | scratch | b02 | **SILENT-WRONG** | expected 0 rows, got 1 zero-row for platform NOKIA_9000 |
| `wr02_case_platform` | scratch | b02 | **SILENT-WRONG** | expected 0 rows, got 1 zero-row for Android_Phone (case twin of a real value) |
| `wr03_star_platform` | scratch | b02 | **SILENT-WRONG** | real platform `'*'`: expected its peak 1, got the all-platform 8 |
| `wr04_real_platform` | scratch | b02 | **SILENT-WRONG** | integral: truth 6840, served 9180 (F2 at platform level) |
| `wr05_collision_rollup` | scratch | b01 | **SILENT-WRONG** | integral: expected 12180, served 15180 (F2 three-way collision) |
| `wr06_collision_content` | scratch | b04 | **SILENT-WRONG** | real content −1: expected peak 1 / 2340 s, served 8 / 15180 s |
| `wr07_unknown_content` | scratch | b04 | **SILENT-WRONG** | expected 0 rows, got 1 zero-row for content 777 |
| `wr08_inverted_range` | scratch | b01 | **LOUD-PASS** | Code 395: p_end must be strictly after p_start |
| `wr09_empty_range` | scratch | b01 | **LOUD-PASS** | Code 395 on start == end |
| `wr10_zero_span` | scratch | b01 | **PASS** | genuinely zero range answers 0/0 |
| `wr11_before_first` | scratch | b01 | **PASS** | 0/0 — defensible, but indistinguishable from "no data yet" |
| `wr12_after_last` | scratch | b01 | **PASS** | 0/0 — same caveat |
| `wr13_one_minute` | scratch | b01 | **PASS** | peak 8, integral 480 == truth |
| `wr14_ragged` | scratch | b11 | **PASS** | peak 8, integral 10080 == truth |
| `wr15_mid_minute` | scratch | b01 | **PASS** | sub-minute range edges: integral 9390 == truth |
| `wr16_sub_minute` | scratch | b01 | **PASS** | 30-second range: integral 240 == truth |
| `wr17_hour_exact` | scratch | b01 | **PASS** | boundary-exact session: 1 / 3600 == truth |
| `wr18_full_span` | scratch | b10 | **SILENT-WRONG** | integral: truth 34860, served 37860 (F2) |
| `wr19_avg_zero_hours` | scratch | b01 | **WRONG** | avg 2.11 vs truth 1.69 (F2 inflating the numerator) |
| `ht01_no_data_day` | scratch | b05 | **PASS** | day with no data serves EMPTY (correct contrast to window family) |
| `ht02_day_hours` | scratch | b05 | **PASS** | exactly the 11 active hours |
| `ht03_day_rollup` | scratch | x05 | **PASS** | peak 8 @ 10:30, integral 33000, avg 0.3819 — all hand-computed |
| `ht04_day2` | scratch | x05 | **PASS** | 1 / 1860 |
| `ht05_tie_earliest` | scratch | x04 | **PASS** | tie at 20:00 and 20:59 → earliest wins (ADR 0014) |
| `ht06_empty_hour` | scratch | x04 | **PASS** | absent hour is absent, not zero |
| `ht07_middle_hour` | scratch | x04 | **PASS** | event-free middle hour: 1 / 3600 |
| `ht08_lastminute_end` | scratch | x04 | **PASS** | 14:59:59 end: 2 / 4560, no leak |
| `ht09_no_leak_hour15` | scratch | x04 | **PASS** | hour 15 clean: 1 / 1800 |
| `ht10_b12_alldays` | scratch | b12 | **PASS** | exactly the 2 days that exist |
| `ht11_top_content_unique` | scratch | b13 | **WRONG** | content 101 listed twice (F3) |
| `ht12_orphan_title` | scratch | b13 | **PASS** | orphan renders `(unknown)`; real −1 asset absent (F3, recorded) |
| `ms01_aligned_hour` | scratch | b06 | **PASS** | all 60 minutes == truth |
| `ms02_midhour` | scratch | b06 | **SILENT-WRONG** | 60/60 minutes wrong at p_hour=10:30 (F4: 2 vs 8) |
| `ms03_empty_hour` | scratch | b06 | **PASS** | quiet hour = 60 explicit zeros |
| `ms04_planted_case_twin` | scratch | b07 | **PASS** | lowercase twin that EXISTS serves exactly |
| `ms05_unknown_platform` | scratch | b07 | **PASS** | all-zero curve, numerically true (see F5 caveat) |
| `vt01_live` | scratch | b08 | **PASS** | catalog filter incl. real content −1: 5 / 23580 == truth |
| `vt02_unknown_type` | scratch | b08 | **SILENT-WRONG** | zero row + epoch peak_minute for unknown type |
| `vt03_case_type` | scratch | b08 | **SILENT-WRONG** | same for case variant `LIVE` |
| `vt04_blank_type` | scratch | b08 | **PASS** | blank type = real empty bucket, 0 — identical in shape to vt02 (F5) |
| `vt05_vod` | scratch | b08 | **PASS** | 2 / 8400 == truth |
| `in01_pair` | scratch | b09 | **PASS** | partial two-platform filter == truth (5 / 12420) |
| `in02_duplicates` | scratch | b09 | **PASS** | duplicate IN entries do not double count |
| `in03_empty_list` | scratch | b09 | **PASS** | empty set answers 0 |
| `in04_single_rare` | scratch | b09 | **PASS** | one-hour-only value found in a full-day range |
| `in05_mixed_unknown` | scratch | b09 | **PASS** | unknown member inert, real member exact |
| `in06_huge_list` | scratch | b09 | **PASS** | 500-element IN == unfiltered day (8 / 33000) |
| `xd01_hour_tier_audio` | scratch | x01 | **LOUD-PASS** | Code 47 — non-carried dimension fails loudly |
| `xd02_raw_hindi` | scratch | x02 | **PASS** | raw equality sees 2 of 4 Hindi spellings (F6, quantified) |
| `xd03_norm_hindi` | scratch | x03 | **PASS** | norm_lang folds all 4, queried via `HIN` |
| `xd04_devanagari` | scratch | x03 | **PASS** | `हिन्दी` stays its own visible bucket (rule limit, by design) |
| `cw01_unknown_platform` | cloud | b02 | **SILENT-WRONG** | deployed: zero-row for unknown platform |
| `cw02_case_platform` | cloud | b02 | **SILENT-WRONG** | deployed: zero-row for android_phone |
| `cw03_inverted_range` | cloud | b01 | **LOUD-PASS** | deployed view refuses inverted range (Code 395) |
| `cw04_empty_range` | cloud | b01 | **LOUD-PASS** | deployed view refuses zero-length range |
| `cw05_before_first` | cloud | b01 | **PASS** | 0/0 before the first event |
| `cw06_real_platform` | cloud | b02 | **SILENT-WRONG** | F1 skew: served 1837 / 5149740 vs intervals-truth 1706 / 4688520 |
| `cw07_ragged` | cloud | b11 | **SILENT-WRONG** | F1 skew: 2950 vs 2681 |
| `cw08_mid_minute` | cloud | b01 | **SILENT-WRONG** | F1 skew: 2379 vs 2154 |
| `cw09_one_minute` | cloud | b01 | **SILENT-WRONG** | F1 skew at the peak minute: 2950 vs 2681 |
| `cw10_duplicates` | cloud | b09 | **SILENT-WRONG** | F1 skew (dupes ≡ single still holds shape-vs-shape) |
| `cw11_empty_list` | cloud | b09 | **PASS** | empty set answers 0 |
| `cw12_huge_list` | cloud | b09 | **SILENT-WRONG** | F1 skew (huge ≡ unfiltered still holds shape-vs-shape) |
| `cw13_unknown_video_type` | cloud | b08 | **SILENT-WRONG** | deployed: zero row + epoch minute |
| `cw14_case_video_type` | cloud | b08 | **SILENT-WRONG** | deployed: same for `Live` |
| `cw15_hour_tier_audio` | cloud | x01 | **LOUD-PASS** | deployed hour tier fails loudly on audio_language |
| `cw16_raw_hindi` | cloud | x02 | **WRONG** | 1798 vs ADR 0011's 1768 — F1 skew on the raw path |
| `cw17_norm_hindi` | cloud | x03 | **WRONG** | 2203 vs 2180 — same skew, norm gap (+22.5%) reproduces |
| `cw18_star_platform` | cloud | b02 | **PASS** | recorded: `'*'` = "all" in this interface (F5 domain collision) |
| `cw19_b06_midhour` | cloud | b06 | **SILENT-WRONG** | deployed b06 at 10:30: all 60 minutes off (F4) |
| `cw20_top_content_unique` | cloud | b13 | **PASS** | 10 distinct content rows (no hostile values in graded data) |
| `cw21_b05_empty_day` | cloud | b05 | **PASS** | day past the data serves empty |

## Invariants — checked across the cube, not at one example

| invariant | target | verdict | headline numbers |
|---|---|---|---|
| `inv1_peak_not_sum_of_dim_peaks` | scratch | **PASS** | truth 8 == served 8; sum of platform peaks 9 (overcount demonstrated) |
| `inv1_peak_not_sum_of_dim_peaks` | cloud | **FAIL** | served 2917 ≠ intervals truth 2681; sum-of-platform-peaks 2758 (F1) |
| `inv2_users_never_summed` | scratch | **PASS** | serving == truth on all 408 minutes; summed overcounts (u01 on 2 platforms) |
| `inv2_users_never_summed` | cloud | **FAIL** | 586/3658 minutes disagree; 74 user-tier minutes with no interval coverage; sum overcounts on 69 minutes (max 9 — trap real on real data) |
| `inv4_day_peak_eq_max_minute` | scratch | **PASS** | 0 peak + 0 integral mismatches at all 8 cube levels (incl. colliding −1) |
| `inv4_day_peak_eq_max_minute` | cloud | **FAIL** | peak mismatches at every level: 2 total, 12 platform, 2 country, 164 content (F1) |
| `inv5_user_le_session` | scratch | **PASS** | 0 violations in 3,926 (grain, minute) cells across all 8 masks |
| `inv5_user_le_session` | cloud | **FAIL** | 643–10,048 violating cells per mask; max excess 247 (11:21: 1489 users vs 1242 sessions) |
| `inv6_join_consistency_orphan` | scratch | **PASS-WITH-DISCLOSURE** | orphan 999 holds 1,020 s (3.09%) — in no video_type answer |
| `inv6_join_consistency_orphan` | cloud | **PASS** | 0 orphan seconds on the graded file |

## Method

- **Fixture** (`fixture/10_fixture_data.sql`): 18 designed intervals + 4 catalog rows in a LOCAL
  scratch db (`robust`), built through the repo's own `sql/` files (00→10→fixture→40→45→50→20→15→
  80→85), so the *current committed code* is what gets probed. Hostile features per row are listed
  in the file; headline hand-computed truths: hour-10 peak 8 @ 10:30 / 12,180 s, day-1 integral
  exactly 33,000 s, per-platform peaks summing to 9 ≠ 8. The loader `throwIf`s on the graded db.
- **Truth** (`truth/*.sql`): independent arithmetic — interval expansion + `uniqExact`, clipped at
  second precision — never the delta/running-sum path under test, so a shared bug cannot cancel.
- **Harness** (`tools/query-robustness.sh` + `cases.tsv` + `compare.py`): one TSV line per (shape,
  condition); expectations are `rows:N` / `value:` / `truth_range` / `truth_series` / `unique:` /
  `error` / `record`. Cloud requests are pinned `readonly=2`; there is no cloud write path.
- **Caveats**: local scratch runs ClickHouse 26.7.1 vs cloud 26.2.1 (shapes behaved identically
  where comparable). Truth uses the model's own minute-membership convention (active from
  `toStartOfMinute(start)` through `toStartOfMinute(end)` inclusive) — whether the *graders* share
  that convention is `doubts/05|09`, out of scope here. `expected 1768/2180` in cw16/cw17 are ADR
  0011's committed measurements; the drift is F1, not ADR error.
