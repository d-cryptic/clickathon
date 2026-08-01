# Codex re-validation — W2 model correctness

> **Summary:** Re-validated W2 SQL/docs at `cf5cc1f`; the branch later advanced to `5065531` only by adding an empty unrelated SQLite file.
> ADR 0009's rejected `sql/40_deltas.sql` defect is fixed: no executable `any()` remains in `sql/`.
> Interval and delta hashes are identical at `max_threads` 1/8/32; the delta hash matches the live 28,073 rows.
> Both gates pass 17,028 / 0 / 0 / 2,917; the requested headline, Hindi, and 98-hour checks all hold.
> **DO NOT PROMOTE:** ADR 0011 is absent from `make model`; ADR 0014's submitted path returns 16:59, not earliest-wins 15:51.

Validated 2026-08-02 from
`/Users/barun/.superconductor/worktrees/clickathon-project/sc-tunneled-cryostat-4c7d`.
All Cloud statements in this report were `SELECT`/`SHOW` or the read-only reconciliation SQL. I never
set `REBUILD_GRADED` or `APPLY_GRADED_DESTRUCTIVE`. I ran no Cloud `INSERT`, `TRUNCATE`, `ALTER`,
`CREATE`, `DROP`, or `OPTIMIZE`.

## Verdicts

| Claim / promotion check | Verdict | Result |
|---|---|---|
| Branch ancestry is based on `main` | **HOLDS** | Merge base is `2b551b5`; the semantic W2 tip tested was `cf5cc1f`. |
| Branch contains only the isolated W2 feature | **DOES NOT HOLD** | Concurrent checkpoint `5065531` adds unrelated empty `sqlite_mcp_server.db`. |
| ADR 0009 same-second rule | **HOLDS** | Both model and gate use `>=`; both filter zero-length pause windows. |
| ADR 0009 all seven dimensions leave executable `any()` | **HOLDS** | No executable `any()` remains in `sql/`; the `sql/40_deltas.sql` fold carries slots `.3`–`.9`. |
| ADR 0009 end-to-end determinism | **HOLDS for the two model stages re-run** | Interval and delta derivations each produced one hash at threads 1/8/32; derived delta equals live. |
| ADR 0011 five UDFs, four views, Hindi 1,774 -> 2,196 live | **HOLDS** | All objects and the +422 / +23.8% result reproduced. |
| ADR 0011 is a coherent promoted feature | **DOES NOT HOLD** | `make model` never applies `sql/15_normalise.sql`; dev follow-up `004ce0e` says the unwired ADR "did nothing" and supplies the missing step. |
| ADR 0014 live stored hour tier | **HOLDS** | Independent `minIf` derivation agrees for 98/98 hours; 0 peak and 0 minute mismatches. |
| ADR 0014 no bare `argMax(minute, ...)` in live views | **HOLDS** | 0 offending live views. |
| ADR 0014 earliest-wins everywhere / coherent isolation | **DOES NOT HOLD** | Branch omits the `sql/50_hour_agg.sql` hunk and keeps two bare `argMax` calls in `tools/unseen-run.sh`; on 2026-07-25 they return 16:35 and 16:59 instead of 15:51. |
| Check 2 build and scratch apply | **HOLDS** | Pinned devbox CI passed; a clean local scratch rebuilt to 30,323 / 28,073 / 26,254 / peak 2,917 and passed the branch gate. |
| Check 4a deployed-spec gate | **HOLDS** | 17,028 minutes, 0 mismatched, max absolute difference 0, peak 2,917. |
| Check 4b branch gate | **HOLDS** | Same exact result; no W2 spec-skew excuse is needed. |
| Check 6 docs current and mutually consistent | **DOES NOT HOLD** | ADR 0011 says both three and four views; the unseen runbook calls both 16:59 and 15:51 the expected good answer; ADR 0014 remains Accepted while its submitted answer path is explicitly open. |

## Environment and branch identity

Exact STEP ZERO commands:

```bash
git fetch origin
git checkout chore/promotion-w2-model-correctness
git log --oneline -6
```

Exact output:

```text
Switched to branch 'chore/promotion-w2-model-correctness'
Your branch is ahead of 'origin/chore/promotion-w2-model-correctness' by 2 commits.

cf5cc1f test: re-run the gate against sonyliv at the answered W2 commit
72d007e fix: the last any() leaves, so ADR 0009's own title becomes true (W2 check 5)
7f5a517 test: re-run the correctness gate at the promotion commit (W2)
201718b feat: promote model correctness onto main — ADR 0009 · 0011 · 0014 (promotion W2)
2b551b5 docs: record what main was before any feature was promoted
c10e97d docs: correct every stale claim in the submission artifacts (Q27)
```

Exact isolation commands:

```bash
git merge-base origin/main HEAD
git log --reverse --format='%h %s' origin/main..HEAD
```

Exact output:

```text
2b551b59b398da3ec82ca784c039c2520f5c7980
201718b feat: promote model correctness onto main — ADR 0009 · 0011 · 0014 (promotion W2)
7f5a517 test: re-run the correctness gate at the promotion commit (W2)
72d007e fix: the last any() leaves, so ADR 0009's own title becomes true (W2 check 5)
cf5cc1f test: re-run the gate against sonyliv at the answered W2 commit
```

During validation, the orchestrator committed the pre-existing empty `sqlite_mcp_server.db` as
`5065531` and pushed it. Exact post-validation delta:

```bash
git show --stat --oneline 5065531
git diff --name-only cf5cc1f..5065531
```

```text
5065531 wip: overnight preservation checkpoint
 sqlite_mcp_server.db | 0
 1 file changed, 0 insertions(+), 0 deletions(-)
sqlite_mcp_server.db
```

No reviewed SQL, tool, or documentation file changed, so all semantic measurements remain applicable.
I did not create or modify that file. **Verdict: HOLDS** for `main` ancestry; **DOES NOT HOLD** for
minimal branch isolation because the unrelated artifact is now tracked.

## Check 1 — isolate the complete feature

### ADR 0009: the rejected `any()` defect is actually closed

Exact command:

```bash
rg -n --pcre2 "^(?!\s*--).*\bany\s*\(" sql --glob '*.sql'
```

Exact output and status:

```text
[no output]
exit 1 (no match)
```

Exact rule audit:

```bash
rg -n "arrayFirst\(x -> x >=? p|arrayFilter\(w -> w\.2 > w\.1" \
  sql/30_build_intervals.sql sql/90_reconcile.sql
```

Exact output:

```text
sql/90_reconcile.sql:116:            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
sql/90_reconcile.sql:118:                        if(arrayFirst(x -> x >= p, p2.rs) = 0,
sql/90_reconcile.sql:121:                              if(arrayFirst(x -> x > p, r.run_ts) = 0, r.r_end, arrayFirst(x -> x > p, r.run_ts))),
sql/90_reconcile.sql:122:                           arrayFirst(x -> x >= p, p2.rs)),
sql/30_build_intervals.sql:191:            -- Hence the outer arrayFilter(w -> w.2 > w.1, …).
sql/30_build_intervals.sql:195:            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
sql/30_build_intervals.sql:197:                        if(arrayFirst(x -> x >= p, resumes) = 0,
sql/30_build_intervals.sql:201:                              if(arrayFirst(x -> x > p, run) = 0, run[length(run)], arrayFirst(x -> x > p, run))),
sql/30_build_intervals.sql:202:                           arrayFirst(x -> x >= p, resumes)),
```

The strict `>` calls are the explicitly retained permissive lookup into the run; the pause-to-resume
lookup is inclusive in both independent implementations. In `sql/40_deltas.sql`, the emitted tuple
now maps platform/country/content_id from `.7/.8/.9`, with the other four dimensions in `.3`–`.6`.

I also executed the branch derivations as read-only subqueries at three thread counts. The command
removed only the leading `INSERT INTO ...` target, wrapped the unchanged query body in a hash, scanned
the generated SQL for write verbs, and sent it to Cloud:

```bash
interval_body="$(awk 'BEGIN { skipping = 0 } /^INSERT INTO session_intervals/ { skipping = 1; next } skipping && /^WITH$/ { skipping = 0 } !skipping { print }' sql/30_build_intervals.sql | sed '$s/;[[:space:]]*$//')"
for thread_count in 1 8 32; do
  query="SELECT ${thread_count} AS max_threads, count() AS interval_rows, hex(groupBitXor(cityHash64(video_session_id, user_id, content_id, platform, country, app_version, audio_language, subtitle_language, player_version, toString(interval_start), toString(interval_end), is_open))) AS derivation_hash FROM (${interval_body}) SETTINGS max_threads=${thread_count}, group_by_two_level_threshold=1, group_by_two_level_threshold_bytes=1 FORMAT TSVWithNames"
  curl -sS --fail-with-body "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$query"
done
```

Exact output:

```text
max_threads	interval_rows	derivation_hash
1	30323	FCA5CCF1B8D809F1
max_threads	interval_rows	derivation_hash
8	30323	FCA5CCF1B8D809F1
max_threads	interval_rows	derivation_hash
32	30323	FCA5CCF1B8D809F1
```

The same command shape over `sql/40_deltas.sql` produced:

```text
max_threads	delta_rows	derivation_hash
1	28073	FF26B61412104CB7
max_threads	delta_rows	derivation_hash
8	28073	FF26B61412104CB7
max_threads	delta_rows	derivation_hash
32	28073	FF26B61412104CB7
```

Exact live-tier comparison:

```bash
tools/ch -c "SELECT count() AS delta_rows, hex(groupBitXor(cityHash64(toString(minute), platform, country, content_id, subtitle_language, player_version, audio_language, app_version, delta, starts, ends))) AS live_hash FROM cc_minute_delta FORMAT TSVWithNames"
```

```text
delta_rows	live_hash
28073	FF26B61412104CB7
```

**Verdict: HOLDS.** The original promotion blocker is closed independently at source, derivation,
and deployed-row levels.

### ADR 0011: the follow-up that makes the feature run was not picked

Exact branch command:

```bash
rg -n "15_normalise" tools/build-model.sh tools/unseen-run.sh
```

Exact output and status:

```text
[no output]
exit 1 (no match)
```

Exact dev-history command:

```bash
git log --reverse --format='%h %s' -S'15_normalise.sql' origin/main..origin/dev -- \
  tools/build-model.sh tools/unseen-run.sh
```

Exact output:

```text
004ce0e fix: close the remaining checkpoint-1 items — wire normalisation, un-stale the runbook, align the test schema
```

That follow-up's commit message says exactly why it exists:

```text
B6-2 — sql/15_normalise.sql is now stage 5/5 of tools/build-model.sh. It was
built, measured and ADR'd (0011) and then never entered the build path, so it did
nothing.
```

The branch does carry the SQL artifact, and a no-argument `tools/apply-sql.sh` glob can install it
manually. But the documented `make model` path does not. The promotion contract requires the smallest
coherent feature and requires `main` to be releasable after each promotion; a feature that exists only
because the graded service was built from later `dev` is not coherent on `main`.

**Verdict: DOES NOT HOLD.** ADR 0011's live objects hold, but the branch did not pick the follow-up
that makes its own build install them.

### ADR 0014: three executable parts of the decision are still absent

The ADR says `sql/50_hour_agg.sql` changed from the indirect hour tie-break to the returned
`peak_minute` itself. Exact branch command and output:

```bash
rg -n -A 1 "argMax\(peak_minute" sql/50_hour_agg.sql
```

```text
275:    argMax(peak_minute, (cc_hour_agg.peak, -toInt64(toUInt32(hour)))) AS peak_minute,
276-    sum(cc_hour_agg.integral) AS integral,
--
287:    argMax(peak_minute, (cc_hour_agg.peak, -toInt64(toUInt32(hour)))) AS peak_minute,
288-    sum(cc_hour_agg.integral) AS integral,
```

Exact feature-commit command and output:

```bash
git show 0446423:sql/50_hour_agg.sql | \
  rg -n -A 1 "argMax\(cc_hour_agg\.peak_minute"
```

```text
308:    argMax(cc_hour_agg.peak_minute,
309-           (cc_hour_agg.peak, -toInt64(toUInt32(cc_hour_agg.peak_minute)))) AS peak_minute,
--
322:    argMax(cc_hour_agg.peak_minute,
323-           (cc_hour_agg.peak, -toInt64(toUInt32(cc_hour_agg.peak_minute)))) AS peak_minute,
```

The branch also keeps both bare display queries that ADR 0014 identifies as the actual rehearsal
bug. Exact command and output:

```bash
rg -n "argMax\(peak_minute,peak\)|argMax\(minute, concurrent\)" tools/unseen-run.sh
```

```text
307:        toString(argMax(peak_minute,peak))) FROM cc_hour_agg FINAL
312:PEAK_MIN=$(q1 "SELECT toString(argMax(minute, concurrent)) FROM v_concurrency_minute_delta_total")
```

This is not theoretical. Exact read-only command against the delivered holdout day:

```bash
tools/ch -c "WITH points AS (SELECT minute, concurrent FROM v_concurrency_minute_delta_total WHERE toDate(minute) = toDate('2026-07-25')), peak AS (SELECT max(concurrent) AS p FROM points) SELECT max(concurrent) AS peak, minIf(minute, concurrent = p) AS earliest_peak_minute, argMax(minute, concurrent) AS bare_argmax_minute, countIf(concurrent = p) AS tied_change_points, groupArrayIf(minute, concurrent = p) AS tied_minutes FROM points CROSS JOIN peak FORMAT TSVWithNames"
```

```text
peak	earliest_peak_minute	bare_argmax_minute	tied_change_points	tied_minutes
13	2026-07-25 15:51:00	2026-07-25 16:59:00	4	['2026-07-25 15:51:00','2026-07-25 16:35:00','2026-07-25 16:55:00','2026-07-25 16:59:00']
```

Exact hour-display query and output:

```bash
tools/ch -c "SELECT max(cc_hour_agg.peak) AS day_peak, argMax(cc_hour_agg.peak_minute, cc_hour_agg.peak) AS bare_hour_tier_minute, argMax(cc_hour_agg.peak_minute, (cc_hour_agg.peak, -toInt64(toUInt32(cc_hour_agg.peak_minute)))) AS earliest_hour_tier_minute FROM cc_hour_agg FINAL WHERE platform = '*' AND country = '*' AND content_id = -1 AND cube_level = 0 AND toDate(hour) = toDate('2026-07-25') FORMAT TSVWithNames"
```

```text
day_peak	bare_hour_tier_minute	earliest_hour_tier_minute
13	2026-07-25 16:35:00	2026-07-25 15:51:00
```

Dev follow-up `990ef8c` replaces these with `min(peak_minute)` / `min(minute)` under the peak filter;
W2 did not pick that follow-up. Calling the script another workstream's owner does not satisfy the
promotion rule: check 1 says promote the smallest coherent group, and the script is explicitly "the
answer (this is what we would submit)."

**Verdict: DOES NOT HOLD.** The ADR's root stored tier is correct, but the promoted decision is not
end to end and its actual submission path demonstrably violates the chosen rule.

## Check 2 — build, tests, and clean scratch

The unpinned host invocation failed before tests because its PATH has golangci-lint v1:

```bash
make ci
```

```text
go mod tidy
go vet ./...
golangci-lint run ./...
Error: you are using a configuration file for golangci-lint v2 with golangci-lint v1: please use golangci-lint v2
Failed executing command with error: you are using a configuration file for golangci-lint v2 with golangci-lint v1: please use golangci-lint v2
make: *** [lint] Error 3
```

Per `docs/GO.md`, exact pinned command:

```bash
devbox run -- make ci
```

Exact substantive output:

```text
go mod tidy
go vet ./...
golangci-lint run ./...
0 issues.
CGO_ENABLED=1 go test -race -count=1 ./...
?   github.com/d-cryptic/clickathon/cmd/sonyliv       [no test files]
?   github.com/d-cryptic/clickathon/internal/chdb     [no test files]
ok  github.com/d-cryptic/clickathon/internal/config   1.613s
ok  github.com/d-cryptic/clickathon/internal/otelemit 2.225s
ok  github.com/d-cryptic/clickathon/internal/pipelinehealth 2.704s
go build -trimpath -ldflags '-s -w -X main.version=cf5cc1f' -o bin/sonyliv ./cmd/sonyliv
```

I created a uniquely named local scratch database, applied the branch files in this exact order, and
copied only local `default.ev_raw`:

```bash
docker exec ch clickhouse-client -q "CREATE DATABASE codex_w2_revalidation_4c7d"
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/00_schema.sql
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/10_intervals.sql
docker exec ch clickhouse-client -q "INSERT INTO codex_w2_revalidation_4c7d.ev_raw SELECT * FROM default.ev_raw"
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/30_build_intervals.sql
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/40_deltas.sql
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/20_views.sql
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/50_hour_agg.sql
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/15_normalise.sql
docker exec -i ch clickhouse-client --database codex_w2_revalidation_4c7d --multiquery < sql/85_windows.sql
```

Exact output from `sql/15_normalise.sql`'s 24 assertions and the tier query:

```text
0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0	0
raw_rows	interval_rows	delta_rows	hour_rows	peak
905558	30323	28073	26254	2917
```

The branch gate on that fresh scratch returned the same six rows as check 4b below, including:

```text
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS │
```

Independent scratch hour comparison:

```text
hours_compared	peak_mismatches	peak_minute_mismatches
98	0	0
```

After enumerating its 30 derived tables/views, I dropped only
`codex_w2_revalidation_4c7d` and verified `remaining=0`. It was temporary derived local state and is
not recoverable or needed. **Verdict: HOLDS.**

## Check 3 — re-derive every live claim

### ADR 0009 same-second counts and hours

Exact command:

```bash
tools/ch -c "WITH pause_rows AS (SELECT video_session_id, toUInt32(event_timestamp) AS pause_second FROM ev_raw WHERE event = 'pause'), resume_seconds AS (SELECT DISTINCT video_session_id, toUInt32(event_timestamp) AS resume_second FROM ev_raw WHERE event = 'resume') SELECT count() AS raw_pause_rows, countIf((video_session_id, pause_second) IN (SELECT video_session_id, resume_second FROM resume_seconds)) AS raw_pause_rows_with_same_second_resume, uniqExact((video_session_id, pause_second)) AS distinct_pause_instants, uniqExactIf((video_session_id, pause_second), (video_session_id, pause_second) IN (SELECT video_session_id, resume_second FROM resume_seconds)) AS distinct_pause_instants_with_same_second_resume, round(100 * raw_pause_rows_with_same_second_resume / raw_pause_rows, 2) AS raw_row_pct, round(100 * distinct_pause_instants_with_same_second_resume / raw_pause_rows, 2) AS effective_over_raw_pct, round(100 * distinct_pause_instants_with_same_second_resume / distinct_pause_instants, 2) AS distinct_instant_pct FROM pause_rows FORMAT TSVWithNames"
```

```text
raw_pause_rows	raw_pause_rows_with_same_second_resume	distinct_pause_instants	distinct_pause_instants_with_same_second_resume	raw_row_pct	effective_over_raw_pct	distinct_instant_pct
27340	2697	27017	2502	9.86	9.15	9.26
```

Exact pause-ledger output from strict and inclusive lookups over both raw and distinct instants:

```text
pause_rows	raw_same_second_rows	raw_row_pct	pause_instants	distinct_same_second_instants	effective_over_raw_pct	strict_hours_raw	inclusive_hours_raw	raw_difference_hours	strict_hours_distinct	inclusive_hours_distinct	distinct_difference_hours
27340	2697	9.86	27017	2502	9.15	834.1	792.6	41.5	830.2	790.4	39.8
```

**Verdict: HOLDS** with ADR 0009's corrected qualification: 2,697 / 41.5 h are raw-ledger figures;
2,502 / 39.8 h are model-instant/deduplicated-ledger figures.

### Headline before and after

I re-ran `main` baseline `2b551b5`'s old gate read-only and filtered its exact output to the summary
and headline minute:

```bash
git show 2b551b5:sql/90_reconcile.sql | curl -sS --fail-with-body \
  "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
  --user "${CH_USER}:${CH_PASSWORD}" --data-binary @- | \
  rg "SUMMARY|2026-07-26 10:56:00"
```

```text
 1. │   0 │ SUMMARY  │ minutes_compared=17028 │ mismatched=177 │ max_abs_diff=39 │ peak=2887 │ MISMATCH │
 5. │   1 │ MISMATCH │ 2026-07-26 10:56:00    │ 2887           │ 2917            │ 30        │ MISMATCH │
25. │   2 │ sample   │ 2026-07-26 10:56:00    │ 2887           │ 2917            │ 30        │ MISMATCH │
```

For historical hours, I removed only the old SQL's leading `INSERT` target, wrapped its unchanged
derivation as a read-only aggregate, scanned for write verbs, and ran it on live `ev_raw`:

```text
interval_rows	counted_hours
30769	1949.3
```

Exact current command and output:

```bash
tools/ch -c "SELECT (SELECT count() FROM session_intervals FINAL) AS interval_rows, (SELECT count() FROM cc_minute_delta) AS delta_rows, (SELECT count() FROM cc_hour_agg FINAL) AS hour_rows, round((SELECT sum(dateDiff('second', interval_start, interval_end)) FROM session_intervals FINAL) / 3600, 1) AS counted_hours, (SELECT max(concurrent) FROM v_concurrency_minute_delta_total) AS peak FORMAT TSVWithNames"
```

```text
interval_rows	delta_rows	hour_rows	counted_hours	peak
30323	28073	26254	1978.1	2917
```

**Verdict: HOLDS.** Peak 2,887 -> 2,917 and hours 1,949.3 -> 1,978.1 were independently re-derived.

### ADR 0011 live UDFs, views, rules, and Hindi

Exact source inventory:

```bash
rg -n "^CREATE OR REPLACE (FUNCTION|VIEW)" sql/15_normalise.sql
```

```text
73:CREATE OR REPLACE FUNCTION norm_case AS (s) -> lower(trimBoth(toString(s)));
90:CREATE OR REPLACE FUNCTION norm_lang AS (s) ->
101:CREATE OR REPLACE FUNCTION norm_version AS (s) -> norm_case(s);
121:CREATE OR REPLACE FUNCTION norm_app_version AS (s) ->
144:CREATE OR REPLACE FUNCTION lang_class AS (s) ->
212:CREATE OR REPLACE VIEW v_cc_minute_delta_norm AS
239:CREATE OR REPLACE VIEW v_concurrency_minute_audio_norm AS
263:CREATE OR REPLACE VIEW v_dimension_drift AS
304:CREATE OR REPLACE VIEW v_dimension_drift_summary AS
```

Exact live object outputs:

```text
name	origin
lang_class	SQLUserDefined
norm_app_version	SQLUserDefined
norm_case	SQLUserDefined
norm_lang	SQLUserDefined
norm_version	SQLUserDefined

name	engine	metadata_modification_time
v_cc_minute_delta_norm	View	2026-08-01 19:32:18
v_concurrency_minute_audio_norm	View	2026-08-01 19:32:19
v_dimension_drift	View	2026-08-01 19:32:19
v_dimension_drift_summary	View	2026-08-01 19:32:20
```

Exact rule-behaviour output:

```text
hin_upper	hin_long	hin_class	app_version	player_version	platform
hin	hin	named	5.0.36	3.33.50_ade	mweb
```

Exact cardinality output:

```text
audio_raw	audio_case	audio_norm	subtitle_raw	subtitle_case	subtitle_norm	app_raw	app_norm	player_raw	player_norm	platform_raw	platform_norm	country_raw	country_norm
41	26	18	11	8	7	65	64	14	14	10	10	1	1
```

Exact Hindi command:

```bash
tools/ch -c "WITH raw AS (SELECT minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta WHERE audio_language = 'hin' GROUP BY minute), normalised AS (SELECT minute, concurrent FROM v_concurrency_minute_audio_norm WHERE audio_language_norm = 'hin') SELECT (SELECT max(concurrent) FROM raw) AS raw_hin_peak, (SELECT max(concurrent) FROM normalised) AS normalised_hin_peak, normalised_hin_peak - raw_hin_peak AS delta, round(100 * delta / raw_hin_peak, 1) AS pct_increase FORMAT TSVWithNames"
```

```text
raw_hin_peak	normalised_hin_peak	delta	pct_increase
1774	2196	422	23.8
```

The unfiltered running sum over `v_cc_minute_delta_norm` still peaks at 2,917. **Verdict: HOLDS** for
the requested live claim; **DOES NOT HOLD** for automatic branch installation, as check 1 shows.

### ADR 0014 live hour tier and live views

Exact independent live query (expected minute is `minIf`, not the tuple `argMax` under test):

```bash
tools/ch -c "WITH points AS (SELECT toStartOfHour(minute) AS hour, minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta GROUP BY hour, minute), maxima AS (SELECT hour, max(concurrent) AS peak FROM points GROUP BY hour), independent AS (SELECT p.hour AS hour, max(m.peak) AS peak, minIf(p.minute, p.concurrent = m.peak) AS peak_minute, countIf(p.concurrent = m.peak) AS change_points_at_peak FROM points AS p INNER JOIN maxima AS m USING (hour) GROUP BY p.hour), stored AS (SELECT hour, peak, peak_minute FROM cc_hour_agg FINAL WHERE platform = '*' AND country = '*' AND content_id = -1 AND cube_level = 0) SELECT count() AS hours_compared, countIf(i.peak != s.peak) AS peak_mismatches, countIf(i.peak_minute != s.peak_minute) AS peak_minute_mismatches, countIf(i.change_points_at_peak >= 2) AS hours_with_tied_max_change_points FROM independent AS i INNER JOIN stored AS s USING (hour) FORMAT TSVWithNames"
```

```text
hours_compared	peak_mismatches	peak_minute_mismatches	hours_with_tied_max_change_points
98	0	0	51
```

Exact live-view bare-form command and output:

```bash
tools/ch -c "SELECT countIf(match(create_table_query, 'argMax\\s*\\(\\s*minute\\s*,\\s*[A-Za-z_]')) AS live_views_with_bare_argmax_minute, groupArrayIf(name, match(create_table_query, 'argMax\\s*\\(\\s*minute\\s*,\\s*[A-Za-z_]')) AS offending_views FROM system.tables WHERE database = 'sonyliv' AND engine = 'View' FORMAT TSVWithNames"
```

```text
live_views_with_bare_argmax_minute	offending_views
0	[]
```

The fix did not disturb either previously confirmed result. **Verdict: HOLDS.**

The wider live ADR is not fully deployed. Exact output:

```text
name	engine	has_peak_minute	has_peak_5m_minute	has_peak_15m_minute	has_peak_60m_minute
v_cc_rolling_dim	View	0	0	0	0
v_cc_rolling_total	View	0	0	0	0
v_cc_window_range	View	0	0	0	0
```

The branch SQL creates those columns and applied cleanly in the fresh local scratch, but live
`sonyliv` has not applied them. **Verdict: DOES NOT HOLD** for ADR 0014's claim that rows 1–9 are
applied live; only the requested 98-hour and no-bare-live-view claims hold.

## Check 4 — both correctness gates

Before either gate, both SQL files were scanned for line-leading
`INSERT|ALTER|DROP|TRUNCATE|CREATE|OPTIMIZE`; neither matched.

Common credential setup (values remained in environment variables and were never printed):

```bash
set -a
. /Users/barun/Developers/personal/clickathon-project/.env
set +a
promotion_ch_host="${CH_HOST#https://}"
promotion_ch_host="${promotion_ch_host#http://}"
promotion_ch_host="${promotion_ch_host%/}"
```

### 4a — `origin/dev` gate against deployed `sonyliv`

Exact command:

```bash
git show origin/dev:sql/90_reconcile.sql | \
curl -sS --fail-with-body \
  "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
  --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
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

### 4b — this branch's own gate against deployed `sonyliv`

Exact command:

```bash
curl -sS --fail-with-body \
  "https://${promotion_ch_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
  --user "${CH_USER}:${CH_PASSWORD}" --data-binary @sql/90_reconcile.sql
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

**Verdict: HOLDS.** W2 has no spec-skew excuse and does not need one; its own gate passes exactly.

## Check 6 — documentation audit

### ADR 0011 contradicts its own executable inventory

Exact command:

```bash
sed -n '216,220p' docs/adr/0011-normalise-filter-dimensions-at-query-time.md
sed -n '274,280p' docs/adr/0011-normalise-filter-dimensions-at-query-time.md
```

Exact relevant output:

```text
## 5 · The rule, as shipped in `sql/15_normalise.sql`

Five pure SQL UDFs, a self-test, three views, and no data.

Verified end to end: applied to an **empty fresh database** containing only `ev_raw` and
`cc_minute_delta` — self-test green (24 assertions), four views created; **re-applied immediately —
still green**
```

The file and live service both have four views. **Verdict: DOES NOT HOLD** for doc consistency.

### ADR 0014 and the unseen runbook still document two answers

Exact command:

```bash
sed -n '69,82p' docs/RUNBOOK_UNSEEN.md
sed -n '213,229p' docs/RUNBOOK_UNSEEN.md
```

Exact relevant output:

```text
### Expected output, tail of a good run
...
VERDICT — GATE PASSED on sonyliv_unseen. peak 13 @ 2026-07-25 16:59:00.

### A8 — "the peak minute" is ambiguous under ties — RESOLVED, but the script still needs a patch
...
the peak minute is the EARLIEST minute at which the peak level is reached, at every tier. The serving layer now
applies that rule everywhere — the answer for 2026-07-25 is **15:51**.
...
**Still outstanding:** the two display queries in `tools/unseen-run.sh` (phases 6 and 7) use a bare
`argMax` and are the actual source of the disagreement
```

The branch's own live query proves 16:59 is what the current script expression returns and 15:51 is
what ADR 0014 requires. A failed check cannot be converted into a pass by naming it as another
workstream's open item. **Verdict: DOES NOT HOLD.**

### Promotion contract update

The branch now carries `origin/dev`'s two-part check 4 and Codex-lineage check 5; the obsolete contract
from the first review is fixed. **Verdict: HOLDS.** It does not cure the two feature-isolation failures
or the contradictory docs above.

## What I could not verify

- The ADR 0014 claim that all 13 objects have identical hashes over 9 runs each was not re-run in full.
  **UNVERIFIABLE in this revalidation at that exact breadth.** I independently replaced its
  load-bearing checks with interval/delta hashes at 1/8/32, fresh-scratch 98/98, live 98/98, and direct
  holdout counterexamples for the two remaining bare forms.
- I did not mutate `sonyliv`, so I did not apply the branch's missing rolling/range view definitions
  there. Their current absence was checked read-only; applying them is an operator decision.
- The semantic checks ran at `cf5cc1f`. The branch and its remote advanced concurrently to `5065531`;
  I verified that the only delta is an empty unrelated `sqlite_mcp_server.db`, so no SQL/doc check
  needed rerunning. I did not assess why that artifact should exist in the promotion branch.

DO NOT PROMOTE — ADR 0014's actual unseen-day submission path still violates earliest-wins on the delivered holdout, returning 16:59 instead of 15:51.
