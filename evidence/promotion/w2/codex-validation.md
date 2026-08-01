# W2 cross-model validation — Codex check 5

> **Summary:** Validated promotion `7f5a517` read-only against Cloud `sonyliv` and local `tie0014`.
> Both gates pass: **17,028 minutes, 0 mismatched, max_abs_diff 0, peak 2,917**. ADR 0011's five UDFs,
> four views, and **1,774 -> 2,196** Hindi result are live. ADR 0014 agrees independently for 98/98
> hours, with no bare live-view `argMax(minute, ...)`. **DO NOT PROMOTE:** ADR 0009 falsely claims
> all seven dimensions leave `any()` and determinism is end to end; `sql/40_deltas.sql` disproves it.

Validated 2026-08-02 from worktree `sc-trapped-pnictide-6834`. The requested branch was already
checked out in `sc-coupled-squid-7842`, so Git refused a second checkout. I detached this worktree at
the branch's exact tip (`7f5a517926d93c8ab3e60812635d9c5ab6b129d5`), ran the validation, then
returned to `chore/w2-model-correctness-validation` to write this file. No Cloud write query was run;
`REBUILD_GRADED` and `APPLY_GRADED_DESTRUCTIVE` were never set.

## Verdicts

| Claim | Verdict | Result |
|---|---|---|
| ADR 0009: 2,697/27,340 = 9.86% raw pause rows have a same-second resume | **HOLDS**, literally | 27,340 raw rows; 2,697 raw matches; 9.86%. |
| ADR 0009: 2,697 pauses were independently affected and 41.5 h was model impact removed | **DOES NOT HOLD** | Duplicate/truncated-equivalent pause rows collapse in the model: 2,502 distinct affected pause instants. The deduplicated raw ledger moves 39.8 h, while the end-to-end model moves 28.8 h. |
| ADR 0009: all seven dimensions leave `any()` / end-to-end determinism | **DOES NOT HOLD** | `sql/40_deltas.sql` still executes `any(platform)`, `any(country)`, and `any(content_id)` and collapses per-interval labels for 25 live sessions with multiple interval platforms. |
| Headline before/after: 2,887 -> 2,917 and 1,949.3 -> 1,978.1 h | **HOLDS** | The committed before-gate evidence reproduces live; current live intervals are 30,323 / 1,978.1 h and the gate peak is 2,917. |
| ADR 0011 objects and Hindi pair live on `sonyliv` | **HOLDS** | Five SQL UDFs, four views, and 1,774 -> 2,196 (+422, +23.8%) reproduced. |
| ADR 0014 stored hour-tier earliest-wins | **HOLDS** | Live and scratch each compare 98 hours with 0 peak and 0 peak-minute mismatches. |
| ADR 0014: no live view retains bare `argMax(minute, ...)` | **HOLDS** | 0 offending live views. The two tumbling views use the tuple tie-break. |
| Check 4a: `origin/dev` gate against the deployed spec | **HOLDS** | 17,028 / 0 / 0 / 2,917. |
| Check 4b: promoting branch's own gate | **HOLDS** | 17,028 / 0 / 0 / 2,917. |
| Docs current and mutually consistent | **DOES NOT HOLD** | ADR 0009 contradicts itself and `sql/40`; the touched unseen-day runbook's first seven lines contradict current `sql/90_reconcile.sql`; branch `docs/PROMOTION.md` is older than the required two-part check 4 on `origin/dev`. |

## Environment and branch identity

Exact command:

```bash
git rev-parse HEAD
git rev-parse chore/promotion-w2-model-correctness
git log --oneline -8 chore/promotion-w2-model-correctness
```

Exact output:

```text
2b551b59b398da3ec82ca784c039c2520f5c7980
7f5a517926d93c8ab3e60812635d9c5ab6b129d5
7f5a517 test: re-run the correctness gate at the promotion commit (W2)
201718b feat: promote model correctness onto main — ADR 0009 · 0011 · 0014 (promotion W2)
2b551b5 docs: record what main was before any feature was promoted
c10e97d docs: correct every stale claim in the submission artifacts (Q27)
bb3baeb docs: the diagram-first artifact series — checkpoint overview plus four deep dives
d6c85e2 docs: the idle-service trap, and why the naive tile and the deck disagree
3eb368e docs: corrected projection verdict in the deck, plus the offline dashboard fallback
020e6fe docs: ClickStack dashboard reference — what every panel shows and how to read it
```

The first hash is the validation branch before detaching; the second is the exact commit validated.

All Cloud commands below used the following exact prefix because this validation worktree has no
`.env`. The credential file was sourced but never printed or copied:

```bash
set -a && source /Users/barun/.superconductor/worktrees/clickathon-project/sc-coupled-squid-7842/.env && set +a &&
```

Exact command:

```bash
tools/ch -c "SELECT currentDatabase() AS database, version() AS version FORMAT TSVWithNames"
```

Exact output:

```text
database	version
sonyliv	26.2.1.525
```

## ADR 0009 — same-second pause/resume

### Raw-row count versus model-effective instants

Exact command (read-only):

```bash
tools/ch -c "WITH pause_rows AS (SELECT video_session_id, toUInt32(event_timestamp) AS pause_second FROM ev_raw WHERE event = 'pause'), resume_seconds AS (SELECT DISTINCT video_session_id, toUInt32(event_timestamp) AS resume_second FROM ev_raw WHERE event = 'resume') SELECT count() AS raw_pause_rows, countIf((video_session_id, pause_second) IN (SELECT video_session_id, resume_second FROM resume_seconds)) AS raw_pause_rows_with_same_second_resume, uniqExact((video_session_id, pause_second)) AS distinct_pause_instants, uniqExactIf((video_session_id, pause_second), (video_session_id, pause_second) IN (SELECT video_session_id, resume_second FROM resume_seconds)) AS distinct_pause_instants_with_same_second_resume, round(100 * raw_pause_rows_with_same_second_resume / raw_pause_rows, 2) AS raw_row_pct, round(100 * distinct_pause_instants_with_same_second_resume / raw_pause_rows, 2) AS effective_over_raw_pct, round(100 * distinct_pause_instants_with_same_second_resume / distinct_pause_instants, 2) AS distinct_instant_pct FROM pause_rows FORMAT TSVWithNames"
```

Exact output:

```text
raw_pause_rows	raw_pause_rows_with_same_second_resume	distinct_pause_instants	distinct_pause_instants_with_same_second_resume	raw_row_pct	effective_over_raw_pct	distinct_instant_pct
27340	2697	27017	2502	9.86	9.15	9.26
```

**Verdict: HOLDS only as a raw event-row count; DOES NOT HOLD as the count of independently affected
pause instants.** The model truncates to `(video_session_id, second)`, and repeated identical pause
windows are idempotent under its `arrayFold`. Thus 2,697/27,340 reproduces only before collapsing
323 repeated/truncated-equivalent pause rows. The effective numerator is 2,502. This explains the
otherwise unexplained conflict with current `origin/dev:docs/PROMOTION.md`, which says 2,502/27,340
(9.15%). If the denominator is also made distinct, the rate is 2,502/27,017 = 9.26%.

### Pause-ledger hours

Exact command (read-only):

```bash
tools/ch -c "WITH per AS (SELECT video_session_id, arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'pause')) AS ps, arraySort(groupArrayIf(toUnixTimestamp(event_timestamp), event = 'resume')) AS rs FROM ev_raw GROUP BY video_session_id), measured AS (SELECT length(ps) AS pause_rows, arrayCount(p -> has(rs, p), ps) AS raw_same_second_rows, length(arrayDistinct(ps)) AS pause_instants, arrayCount(p -> has(rs, p), arrayDistinct(ps)) AS distinct_same_second_instants, arraySum(arrayMap(p -> if(arrayFirst(x -> x > p, rs) = 0, 0, arrayFirst(x -> x > p, rs) - p), ps)) AS strict_seconds_raw, arraySum(arrayMap(p -> if(arrayFirst(x -> x >= p, rs) = 0, 0, arrayFirst(x -> x >= p, rs) - p), ps)) AS inclusive_seconds_raw, arraySum(arrayMap(p -> if(arrayFirst(x -> x > p, arrayDistinct(rs)) = 0, 0, arrayFirst(x -> x > p, arrayDistinct(rs)) - p), arrayDistinct(ps))) AS strict_seconds_distinct, arraySum(arrayMap(p -> if(arrayFirst(x -> x >= p, arrayDistinct(rs)) = 0, 0, arrayFirst(x -> x >= p, arrayDistinct(rs)) - p), arrayDistinct(ps))) AS inclusive_seconds_distinct FROM per) SELECT sum(pause_rows) AS pause_rows, sum(raw_same_second_rows) AS raw_same_second_rows, round(100 * raw_same_second_rows / pause_rows, 2) AS raw_row_pct, sum(pause_instants) AS pause_instants, sum(distinct_same_second_instants) AS distinct_same_second_instants, round(100 * distinct_same_second_instants / pause_rows, 2) AS effective_over_raw_pct, round(sum(strict_seconds_raw) / 3600, 1) AS strict_hours_raw, round(sum(inclusive_seconds_raw) / 3600, 1) AS inclusive_hours_raw, round((sum(strict_seconds_raw) - sum(inclusive_seconds_raw)) / 3600, 1) AS raw_difference_hours, round(sum(strict_seconds_distinct) / 3600, 1) AS strict_hours_distinct, round(sum(inclusive_seconds_distinct) / 3600, 1) AS inclusive_hours_distinct, round((sum(strict_seconds_distinct) - sum(inclusive_seconds_distinct)) / 3600, 1) AS distinct_difference_hours FROM measured FORMAT TSVWithNames"
```

Exact output:

```text
pause_rows	raw_same_second_rows	raw_row_pct	pause_instants	distinct_same_second_instants	effective_over_raw_pct	strict_hours_raw	inclusive_hours_raw	raw_difference_hours	strict_hours_distinct	inclusive_hours_distinct	distinct_difference_hours
27340	2697	9.86	27017	2502	9.15	834.1	792.6	41.5	830.2	790.4	39.8
```

**Verdict: HOLDS as the ADR's explicitly raw pause-ledger calculation. DOES NOT HOLD if described as
41.5 h removed from the model.** Once identical model instants are collapsed, the same raw ledger
changes by 39.8 h. The actual end-to-end counted-watch-time change is 28.8 h, as the before/after
headline establishes below. The ADR body correctly calls 41.5 h a raw figure, but the promotion
brief's unqualified “41.5 h of over-exclusion removed” overstates model impact.

### Before and after headline

Exact committed-evidence command:

```bash
git show 7f5a517:evidence/promotion/w2/gate-before-2b551b5.txt
```

Its summary and peak row are:

```text
GATE 'BEFORE' — main HEAD 2b551b5's sql/90_reconcile.sql (pre-ADR-0009, strict >) run read-only
against the live sonyliv service, 2026-08-02. Command:
  git show 2b551b5:sql/90_reconcile.sql > /tmp/90_before.sql
  curl -sS "https://<CH_HOST>:<CH_PORT>/?database=sonyliv&default_format=PrettyCompact" --user ... --data-binary @/tmp/90_before.sql

 1. │   0 │ SUMMARY  │ minutes_compared=17028 │ mismatched=177 │ max_abs_diff=39 │ peak=2887 │ MISMATCH │
 5. │   1 │ MISMATCH │ 2026-07-26 10:56:00    │ 2887           │ 2917            │ 30        │ MISMATCH │
```

I independently reran the old gate. Exact command:

```bash
promotion_ch_host="${CH_HOST#https://}" && promotion_ch_host="${promotion_ch_host%/}" &&
git show 2b551b5:sql/90_reconcile.sql |
curl -sS --fail-with-body "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
```

Exact output:

```text
    ┌─ord─┬─scope────┬─c1─────────────────────┬─c2─────────────┬─c3──────────────┬─c4────────┬─verdict──┐
 1. │   0 │ SUMMARY  │ minutes_compared=17028 │ mismatched=177 │ max_abs_diff=39 │ peak=2887 │ MISMATCH │
 2. │   1 │ MISMATCH │ 2026-07-26 10:47:00    │ 2526           │ 2554            │ 28        │ MISMATCH │
 3. │   1 │ MISMATCH │ 2026-07-26 10:52:00    │ 2730           │ 2758            │ 28        │ MISMATCH │
 4. │   1 │ MISMATCH │ 2026-07-26 10:55:00    │ 2833           │ 2860            │ 27        │ MISMATCH │
 5. │   1 │ MISMATCH │ 2026-07-26 10:56:00    │ 2887           │ 2917            │ 30        │ MISMATCH │
 6. │   1 │ MISMATCH │ 2026-07-26 10:57:00    │ 2854           │ 2885            │ 31        │ MISMATCH │
 7. │   1 │ MISMATCH │ 2026-07-26 10:58:00    │ 2828           │ 2855            │ 27        │ MISMATCH │
 8. │   1 │ MISMATCH │ 2026-07-26 10:59:00    │ 2857           │ 2890            │ 33        │ MISMATCH │
 9. │   1 │ MISMATCH │ 2026-07-26 11:00:00    │ 2836           │ 2873            │ 37        │ MISMATCH │
10. │   1 │ MISMATCH │ 2026-07-26 11:01:00    │ 2826           │ 2865            │ 39        │ MISMATCH │
11. │   1 │ MISMATCH │ 2026-07-26 11:02:00    │ 2810           │ 2846            │ 36        │ MISMATCH │
12. │   1 │ MISMATCH │ 2026-07-26 11:03:00    │ 2771           │ 2803            │ 32        │ MISMATCH │
13. │   1 │ MISMATCH │ 2026-07-26 11:04:00    │ 2763           │ 2789            │ 26        │ MISMATCH │
14. │   1 │ MISMATCH │ 2026-07-26 11:05:00    │ 2703           │ 2732            │ 29        │ MISMATCH │
15. │   1 │ MISMATCH │ 2026-07-26 11:06:00    │ 2650           │ 2679            │ 29        │ MISMATCH │
16. │   1 │ MISMATCH │ 2026-07-26 11:07:00    │ 2612           │ 2645            │ 33        │ MISMATCH │
17. │   1 │ MISMATCH │ 2026-07-26 11:08:00    │ 2535           │ 2571            │ 36        │ MISMATCH │
18. │   1 │ MISMATCH │ 2026-07-26 11:09:00    │ 2512           │ 2547            │ 35        │ MISMATCH │
19. │   1 │ MISMATCH │ 2026-07-26 11:10:00    │ 2450           │ 2483            │ 33        │ MISMATCH │
20. │   1 │ MISMATCH │ 2026-07-26 11:11:00    │ 2358           │ 2386            │ 28        │ MISMATCH │
21. │   1 │ MISMATCH │ 2026-07-26 11:12:00    │ 2296           │ 2324            │ 28        │ MISMATCH │
22. │   2 │ sample   │ 2026-07-14 15:43:00    │ 1              │ 1               │ 0         │ PASS     │
23. │   2 │ sample   │ 2026-07-16 12:35:00    │ 0              │ 0               │ 0         │ PASS     │
24. │   2 │ sample   │ 2026-07-17 08:56:00    │ 0              │ 0               │ 0         │ PASS     │
25. │   2 │ sample   │ 2026-07-26 10:56:00    │ 2887           │ 2917            │ 30        │ MISMATCH │
26. │   2 │ sample   │ 2026-07-26 11:30:00    │ 193            │ 197             │ 4         │ MISMATCH │
    └─────┴──────────┴────────────────────────┴────────────────┴─────────────────┴───────────┴──────────┘
```

Exact current-state command:

```bash
tools/ch -c "SELECT count() AS interval_rows, round(sum(dateDiff('second', interval_start, interval_end)) / 3600, 1) AS counted_hours FROM session_intervals FINAL FORMAT TSVWithNames"
```

Exact output:

```text
interval_rows	counted_hours
30323	1978.1
```

**Verdict: HOLDS.** The before peak 2,887 is not merely asserted in a commit message: the committed
artifact contains it, and the old gate independently reproduced it against the current live serving
layer. The current branch/deployed gate supplies the after peak 2,917. The 1,949.3 h before value is
historical rather than recoverable from the already rebuilt graded tables, but its paired old-gate
peak is independently real and the current 1,978.1 h is live.

### The promoted determinism claim fails in the next pipeline stage

Exact command:

```bash
sed -n '214,224p' docs/adr/0009-same-second-resume-and-deterministic-attribution.md
sed -n '74,92p' sql/40_deltas.sql
```

Exact output:

```text
- **`sql/40_deltas.sql` still uses `any(platform)`, `any(country)`, `any(content_id)`** over
  `session_intervals`, so the delta layer re-introduces exactly the non-determinism this ADR removes
  from the derivation, and it *collapses* the new per-interval attribution back to one value per
  session. That file was out of scope for this change and its own comment records the choice
  ("moving those to a different rule would move numbers this task is not allowed to move"). It is now
  the last `any()` in the pipeline and should be closed the same way. **Filed, not fixed.**
-- platform / country / content_id keep any(). They are NOT part of this change:
-- 0 sessions carry two content_ids and 95 carry two platforms, and moving those
-- to a different rule would move numbers this task is not allowed to move. The
-- non-determinism of any() on them is real and is written up in ADR 0008 as a
-- separate, owner-facing decision — it shifts the user peak 2,815 -> 2,816.
merged AS
(
    SELECT
        video_session_id,
        any(platform)   AS platform,
        any(country)    AS country,
        any(content_id) AS content_id,
```

Exact live exposure command:

```bash
tools/ch -c "SELECT countIf(platforms > 1) AS sessions_with_multiple_interval_platforms, countIf(countries > 1) AS sessions_with_multiple_interval_countries, countIf(contents > 1) AS sessions_with_multiple_interval_contents FROM (SELECT video_session_id, uniqExact(platform) AS platforms, uniqExact(country) AS countries, uniqExact(content_id) AS contents FROM session_intervals FINAL GROUP BY video_session_id) FORMAT TSVWithNames"
```

Exact output:

```text
sessions_with_multiple_interval_platforms	sessions_with_multiple_interval_countries	sessions_with_multiple_interval_contents
25	0	0
```

One direct example, exact command:

```bash
tools/ch -c "SELECT video_session_id, arraySort(groupArray((interval_start, interval_end, toString(platform)))) AS attributed_intervals, any(platform) AS sql40_platform FROM session_intervals FINAL GROUP BY video_session_id HAVING uniqExact(platform) > 1 ORDER BY video_session_id LIMIT 1 FORMAT TSVWithNames"
```

Exact output:

```text
video_session_id	attributed_intervals	sql40_platform
05B41D5FF6826EB6BADB80547B077D2B0632512BE515E4D4F5D526797F556A12	[('2026-07-26 10:33:29.000','2026-07-26 10:36:49.000','ANDROID_TAB'),('2026-07-26 10:37:55.000','2026-07-26 10:42:09.000','ANDROID_TAB'),('2026-07-26 10:47:48.000','2026-07-26 11:06:34.000','ANDROID_TAB'),('2026-07-26 11:08:29.000','2026-07-26 11:12:16.000','ANDROID_PHONE')]	ANDROID_TAB
```

The `ANDROID_PHONE` interval is relabelled `ANDROID_TAB` before the serving delta is emitted. The
unfiltered gate cannot detect this because labels do not change total concurrency. Three read-only
hashes of the current part layout at `max_threads=1/8/32` happened to be identical
(`18401438217728165976` each), so I did **not** reproduce run-to-run variation live. That does not
make the promoted statement true: executable `any()` remains and the actual label collapse above is
visible. ADR 0009 itself calls this “exactly the non-determinism this ADR removes” while its title and
summary claim all seven dimensions left `any()` and determinism was proven end to end.

**Verdict: DOES NOT HOLD.** This is the promotion-blocking finding.

## ADR 0011 — live normalisation

Exact UDF command:

```bash
tools/ch -c "SELECT name, origin FROM system.functions WHERE name IN ('lang_class','norm_app_version','norm_case','norm_lang','norm_version') ORDER BY name FORMAT TSVWithNames"
```

Exact output:

```text
name	origin
lang_class	SQLUserDefined
norm_app_version	SQLUserDefined
norm_case	SQLUserDefined
norm_lang	SQLUserDefined
norm_version	SQLUserDefined
```

Exact view command:

```bash
tools/ch -c "SELECT name, engine, metadata_modification_time FROM system.tables WHERE database = 'sonyliv' AND name IN ('v_cc_minute_delta_norm','v_concurrency_minute_audio_norm','v_dimension_drift','v_dimension_drift_summary') ORDER BY name FORMAT TSVWithNames"
```

Exact output:

```text
name	engine	metadata_modification_time
v_cc_minute_delta_norm	View	2026-08-01 19:32:18
v_concurrency_minute_audio_norm	View	2026-08-01 19:32:19
v_dimension_drift	View	2026-08-01 19:32:19
v_dimension_drift_summary	View	2026-08-01 19:32:20
```

Exact behavior command:

```bash
tools/ch -c "SELECT norm_lang('HIN') AS hin_upper, norm_lang('hin-Hindi') AS hin_long, lang_class('HIN') AS hin_class, norm_app_version('5.0.36.00') AS app_version, norm_version('3.33.50_ADE') AS player_version, norm_case('Mweb') AS platform FORMAT TSVWithNames"
```

Exact output:

```text
hin_upper	hin_long	hin_class	app_version	player_version	platform
hin	hin	named	5.0.36	3.33.50_ade	mweb
```

Exact Hindi-pair command:

```bash
tools/ch -c "WITH raw AS (SELECT minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta WHERE audio_language = 'hin' GROUP BY minute), normalised AS (SELECT minute, concurrent FROM v_concurrency_minute_audio_norm WHERE audio_language_norm = 'hin') SELECT (SELECT max(concurrent) FROM raw) AS raw_hin_peak, (SELECT max(concurrent) FROM normalised) AS normalised_hin_peak, normalised_hin_peak - raw_hin_peak AS delta, round(100 * delta / raw_hin_peak, 1) AS pct_increase FORMAT TSVWithNames"
```

Exact output:

```text
raw_hin_peak	normalised_hin_peak	delta	pct_increase
1774	2196	422	23.8
```

**Verdict: HOLDS.** The ADR's dated addendum correctly distinguishes the historical 1,768 -> 2,180
pair from the live post-ADR-0009 1,774 -> 2,196 pair.

## ADR 0014 — earliest peak-minute tie-break

### Independent live hour-tier derivation

Exact command (the expected minute is `minIf`, not the tuple `argMax` under test):

```bash
tools/ch -c "WITH points AS (SELECT toStartOfHour(minute) AS hour, minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta GROUP BY hour, minute), maxima AS (SELECT hour, max(concurrent) AS peak FROM points GROUP BY hour), independent AS (SELECT p.hour AS hour, any(m.peak) AS peak, minIf(p.minute, p.concurrent = m.peak) AS peak_minute, countIf(p.concurrent = m.peak) AS change_points_at_peak FROM points AS p INNER JOIN maxima AS m USING (hour) GROUP BY p.hour), stored AS (SELECT hour, peak, peak_minute FROM cc_hour_agg FINAL WHERE platform = '*' AND country = '*' AND content_id = -1 AND cube_level = 0) SELECT count() AS hours_compared, countIf(i.peak != s.peak) AS peak_mismatches, countIf(i.peak_minute != s.peak_minute) AS peak_minute_mismatches, countIf(i.change_points_at_peak >= 2) AS hours_with_tied_max_change_points FROM independent AS i INNER JOIN stored AS s USING (hour) FORMAT TSVWithNames"
```

Exact output:

```text
hours_compared	peak_mismatches	peak_minute_mismatches	hours_with_tied_max_change_points
98	0	0	51
```

**Verdict: HOLDS.** All 98 live hours agree, and 51 hours have at least two max-valued change
points under the promotion evidence's definition.

### Existing local scratch derivation

Exact commands:

```bash
docker exec ch clickhouse-client --database tie0014 -q "WITH points AS (SELECT toStartOfHour(minute) AS hour, minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta GROUP BY hour, minute), maxima AS (SELECT hour, max(concurrent) AS peak FROM points GROUP BY hour), independent AS (SELECT p.hour AS hour, any(m.peak) AS peak, minIf(p.minute, p.concurrent = m.peak) AS peak_minute FROM points AS p INNER JOIN maxima AS m USING (hour) GROUP BY p.hour), stored AS (SELECT hour, peak, peak_minute FROM cc_hour_agg FINAL WHERE platform = '*' AND country = '*' AND content_id = -1) SELECT count() AS hours_compared, countIf(i.peak != s.peak) AS peak_mismatches, countIf(i.peak_minute != s.peak_minute) AS peak_minute_mismatches FROM independent AS i INNER JOIN stored AS s USING (hour) FORMAT TSVWithNames"

docker exec ch clickhouse-client --database tie0014 -q "WITH tumbling AS (SELECT window_start AS hour, peak, peak_minute FROM v_cc_tumbling_total(win = 60)), stored AS (SELECT hour, peak, peak_minute FROM cc_hour_agg FINAL WHERE platform = '*' AND country = '*' AND content_id = -1) SELECT count() AS windows_compared, countIf(t.peak != s.peak) AS peak_mismatches, countIf(t.peak_minute != s.peak_minute) AS peak_minute_mismatches FROM tumbling AS t INNER JOIN stored AS s USING (hour) FORMAT TSVWithNames"
```

Exact outputs:

```text
hours_compared	peak_mismatches	peak_minute_mismatches
98	0	0

windows_compared	peak_mismatches	peak_minute_mismatches
98	0	0
```

**Verdict: HOLDS for the contents of the pre-existing `tie0014` scratch database.** I did not
rebuild it, so its provenance as a byte-for-byte application of promotion commit `7f5a517` is
unverified; rebuilding was intentionally avoided because this reviewer owns only this evidence file.

### Bare `argMax(minute, ...)` in live views

Exact command:

```bash
tools/ch -c "SELECT countIf(match(create_table_query, 'argMax\\s*\\(\\s*minute\\s*,\\s*[A-Za-z_]')) AS live_views_with_bare_argmax_minute, groupArrayIf(name, match(create_table_query, 'argMax\\s*\\(\\s*minute\\s*,\\s*[A-Za-z_]')) AS offending_views FROM system.tables WHERE database = 'sonyliv' AND engine = 'View' FORMAT TSVWithNames"
```

Exact output:

```text
live_views_with_bare_argmax_minute	offending_views
0	[]
```

The only live views whose first `argMax` argument is `minute` are the two tumbling views, and both
use `(concurrent, -toInt64(toUInt32(minute)))`. **Verdict: HOLDS.**

The broader ADR is not fully implemented in branch-owned executable paths. Exact command:

```bash
rg -n "argMax\(minute, truth\)|argMax\(minute, concurrent\)|argMax\(peak_minute,peak\)" sql/90_reconcile.sql tools/unseen-run.sh
```

Exact output:

```text
sql/90_reconcile.sql:216:            (SELECT argMax(minute, truth) FROM compared),
tools/unseen-run.sh:307:        toString(argMax(peak_minute,peak))) FROM cc_hour_agg FINAL
tools/unseen-run.sh:312:PEAK_MIN=$(q1 "SELECT toString(argMax(minute, concurrent)) FROM v_concurrency_minute_delta_total")
```

The promotion evidence discloses these as unapplied, but that conflicts with ADR 0014's Accepted
status and its own statement that the gate sample “should match” the earliest-wins rule. The live-view
claim holds; the broader “ADR 0014 is promoted” wording is incomplete.

## Check 4 — both gates

The common exact curl setup was:

```bash
promotion_ch_host="${CH_HOST#https://}" && promotion_ch_host="${promotion_ch_host%/}"
curl -sS --fail-with-body "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
```

### 4a — deployed spec (`origin/dev`)

Exact command:

```bash
git show origin/dev:sql/90_reconcile.sql | curl -sS --fail-with-body "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
```

Exact output:

```text
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

**Verdict: HOLDS.**

### 4b — promotion commit `7f5a517`'s own gate

Exact command, run while detached at `7f5a517`:

```bash
curl -sS --fail-with-body "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" --user "${CH_USER}:${CH_PASSWORD}" --data-binary @- < sql/90_reconcile.sql
```

Exact output:

```text
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

**Verdict: HOLDS.** Unlike W1, there is no spec-skew excuse needed: the two gate SQL files agree.

## Documentation audit

### ADR 0009 contradicts itself and executable SQL

The exact output under “The promoted determinism claim fails” shows the ADR title/summary claims all
seven dimensions left `any()` and one hash proves the result end to end, while its Consequences
section admits `sql/40_deltas.sql` reintroduces the same `any()` behavior. This is a direct internal
contradiction, not merely a stale historical measurement. **Verdict: DOES NOT HOLD.**

### The touched unseen-day runbook contradicts the current gate

Exact command:

```bash
sed -n '1,12p' docs/RUNBOOK_UNSEEN.md
sed -n '210,222p' sql/90_reconcile.sql
```

Exact relevant output:

```text
> committed gate `sql/90_reconcile.sql` does NOT work on a new day — its five target minutes are
> 2026-07-26 literals, so it returns zero rows and `tools/reconcile.sh` reports PASS having compared
> nothing.

    -- Sample minutes DERIVED from the data: the peak, both boundaries, and two
    -- picked by a stable hash so the choice is reproducible but not cherry-picked.
    samples AS
    (
        SELECT arrayJoin([
            (SELECT argMax(minute, truth) FROM compared),
            (SELECT min(minute) FROM compared),
            (SELECT max(minute) FROM compared),
```

`docs/RUNBOOK_UNSEEN.md` is in the W2 diff, so check 6 cannot dismiss it as an untouched historical
record. Its first-seven-line summary states the opposite of the branch's current gate and also
contradicts `WALKTHROUGH.md`, which says the gate derives its own targets. **Verdict: DOES NOT HOLD.**

### The branch carries an obsolete promotion contract

Exact comparison:

```bash
git show origin/dev:docs/PROMOTION.md | sed -n '82,94p'
sed -n '38,51p' docs/PROMOTION.md
```

Exact relevant output:

```text
**4b · Run the promoting branch's OWN gate too, and account for any difference.** If it disagrees,
the difference must be explained as **known spec skew** with the commit that causes it named.

**Why this is stricter, not weaker.** ... ADR 0009's same-second resume fix (`>` -> `>=`), which affects
**2,502 of 27,340 pauses (9.15%)**.

**4 · The correctness gate.** `TARGET=cloud tools/reconcile.sh` must still report **17,028 minutes ·
0 mismatched · peak 2,917**.

**5 · Cross-model validation.** A **`claude-fable-5`** agent ...
```

The task explicitly required `origin/dev`'s two-part check 4 and a Codex validator. The promoting
branch's `docs/PROMOTION.md` still contains the older one-part check and the prior reviewer lineage.
The gates were nevertheless run under the current contract in this report. **Verdict: DOES NOT
HOLD** for branch documentation currency.

## What I could not verify

- I did not run `make ci`; that is promotion check 2, not this check 5, and it can write generated
  repository artifacts outside this reviewer's single-file ownership.
- I did not rebuild a scratch database. I verified the existing `tie0014` database read-only, but
  cannot prove its provenance from `7f5a517`; therefore only the scratch result, not the scratch
  construction, is verified here.
- I did not rerun the full 13-object x 9-run determinism harness in
  `evidence/tie-break-determinism.txt`; I independently checked the load-bearing live and scratch
  98-hour comparisons instead.
- I could not recover the pre-fix 1,949.3 h directly from live tables because the graded database has
  already been rebuilt. I verified its paired 2,887 peak by rerunning the pre-fix gate, and verified
  the current 1,978.1 h directly.
- The `sql/40_deltas.sql` `any()` hash did not vary in three current live reads at max_threads
  1/8/32. The code-level claim still fails and the per-interval platform collapse is directly shown,
  but live run-to-run hash variation itself is not reproduced in this snapshot.

DO NOT PROMOTE — ADR 0009's promoted end-to-end determinism claim is false: `sql/40_deltas.sql` still executes `any()` on the serving path.
