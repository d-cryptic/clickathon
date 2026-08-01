# CODEX check 5 — `promo/core`
> **Summary:** **DO NOT PROMOTE.** The combined increment is not a coherent runnable state.
> The stated copy claim **HOLDS**: exactly 64 changed files match `origin/dev`, including every changed `tools/` and `sql/` file.
> Check 1 **DOES NOT HOLD**: promoted tools require omitted `dev` files, and the advertised unseen path necessarily calls one of them.
> Check 2 **DOES NOT HOLD**: pinned `make ci` passes, but `sql/87_viz.sql` fails on a clean scratch database by reading `sonyliv.dict_content`.
> Check 3 **DOES NOT HOLD**: newline forms are caught, but CRLF and block-comment-separated destructive SQL still bypass the graded scanner.
> Check 4a and 4b **HOLD** identically at 17,028 minutes · 0 mismatched · max absolute difference 0 · peak 2,917; Check 6 **DOES NOT HOLD**.

Validated 2026-08-02 from commit `deda6f4657d39ef767d01c36f1e0212a9b521105`, base
`2b551b59b398da3ec82ca784c039c2520f5c7980f`. I made no product fix and wrote only this report.
The pre-existing untracked `sqlite_mcp_server.db` was not touched. Every Cloud request in this audit was
`SELECT` or `EXPLAIN SYNTAX`; no override named in the prohibition was set. One disposable local
Memory table and one disposable local database were created for parser/scratch checks and removed.

## Step Zero and procedure

Command:

```bash
git fetch origin
git checkout promo/core
git log --oneline -2
```

Exact output:

```text
Switched to branch 'promo/core'
Your branch is ahead of 'main' by 1 commit.
  (use "git push" to publish your local commits)
deda6f4 promote: the model and the tooling that runs it (core increment)
2b551b5 docs: record what main was before any feature was promoted
```

I read the six checks with:

```bash
git show origin/dev:docs/PROMOTION.md
```

Verdict: **HOLDS** — the branch is exactly one commit off the stated `main` base. I did not merge
`dev` into any branch.

## Check 1 — isolate and coherence

### Claim 1.1 — all 64 copied files are byte-identical to `origin/dev`

Command:

```bash
base=2b551b5
same=0; different=0; absent=0
while IFS= read -r file; do
  head_blob=$(git rev-parse "HEAD:$file")
  if git cat-file -e "origin/dev:$file" 2>/dev/null; then
    dev_blob=$(git rev-parse "origin/dev:$file")
    if [ "$head_blob" = "$dev_blob" ]; then
      same=$((same+1))
    else
      printf 'DIFFERS %s\n' "$file"
      different=$((different+1))
    fi
  else
    printf 'ABSENT_ON_DEV %s\n' "$file"
    absent=$((absent+1))
  fi
done < <(git diff --name-only "$base"..HEAD)
printf 'same=%d different=%d absent_on_dev=%d total=%d\n' \
  "$same" "$different" "$absent" "$((same+different+absent))"
printf 'tools_sql_diff_count='
git diff --name-only HEAD..origin/dev -- tools sql | wc -l
```

Exact output:

```text
DIFFERS docs/RUNBOOK_UNSEEN.md
ABSENT_ON_DEV docs/codex-validation/004.md
same=64 different=1 absent_on_dev=1 total=66
tools_sql_diff_count=       0
```

Verdict: **HOLDS** for the stated 64-file copy claim. The two other commit files are not part of that
copy set: this branch deliberately edits `docs/RUNBOOK_UNSEEN.md`, and carries the earlier Codex report
which is absent on `origin/dev`. All 46 changed `tools/`/`sql/` files match `origin/dev` byte-for-byte.

### Claim 1.2 — the combined increment contains every cross-file dependency it needs

Command:

```bash
for file in \
  queries/validate_source_contract.sql \
  evidence/liveness/vocabulary.tsv \
  evidence/benchmark/b01_day_peak_avg_total.sql \
  evidence/query-robustness/cases.tsv \
  evidence/landing/identity.txt; do
  if [ -e "$file" ]; then head_state=PRESENT; else head_state=ABSENT; fi
  if git cat-file -e "origin/dev:$file" 2>/dev/null; then dev_state=PRESENT; else dev_state=ABSENT; fi
  printf '%-7s %-7s %s\n' "$head_state" "$dev_state" "$file"
done
```

Exact output:

```text
ABSENT  PRESENT queries/validate_source_contract.sql
ABSENT  PRESENT evidence/liveness/vocabulary.tsv
ABSENT  PRESENT evidence/benchmark/b01_day_peak_avg_total.sql
ABSENT  PRESENT evidence/query-robustness/cases.tsv
ABSENT  PRESENT evidence/landing/identity.txt
```

These are executable dependencies, not prose-only references:

```bash
rg -n 'SQL_FILE=|VOCAB=|dies without|BENCH_DIR=|RB=evidence/query-robustness|validate-source-contract' \
  tools/validate-source-contract.sh tools/bench.sh tools/query-robustness.sh tools/unseen-run.sh
```

Relevant exact output:

```text
tools/validate-source-contract.sh:16:# 2 = could not run. The vocabulary contract is evidence/liveness/vocabulary.tsv
tools/validate-source-contract.sh:36:SQL_FILE="$ROOT/queries/validate_source_contract.sql"
tools/validate-source-contract.sh:37:VOCAB="$ROOT/evidence/liveness/vocabulary.tsv"
tools/bench.sh:20:BENCH_DIR=evidence/benchmark
tools/query-robustness.sh:34:RB=evidence/query-robustness
tools/unseen-run.sh:349:if [ -x tools/validate-source-contract.sh ]; then
tools/unseen-run.sh:352:  if tools/validate-source-contract.sh $CONTRACT_ARGS --database "$DB" 2>&1 | tee -a "$OUT"; then
```

The source-contract tool proves the failure before making a request:

```bash
tools/validate-source-contract.sh -c --database sonyliv
```

Exact failure:

```text
validate-source-contract: missing /Users/barun/.superconductor/worktrees/clickathon-project/sc-coherent-fluxon-70c0/queries/validate_source_contract.sql
```

Consequences on this tree:

- `tools/validate-source-contract.sh` cannot run because both mandatory inputs are absent.
- `tools/unseen-run.sh` sees that tool as executable, calls it after loading, and aborts unless the
  operator sets an acknowledgement override. The one-command unseen path is therefore not runnable.
- `tools/bench.sh` has no benchmark query set.
- `tools/query-robustness.sh` has no cases, fixtures, shapes, truths, invariants, or comparator.
- ADR 0030 names `evidence/landing/identity.txt` as owned proof, but the accepted ADR was promoted
  without that proof.

Verdict: **DOES NOT HOLD** — copying all of `tools/` and `sql/` still did not produce their runnable
dependency closure. The omitted dependencies exist on `origin/dev`, so this is another incomplete
file-state promotion, not an external-data limitation.

## Check 2 — build, tests, and scratch SQL

### Claim 2.1 — `make ci` is green from the documented pinned shell

The ambient shell had golangci-lint v1 and correctly could not read the v2 config. Per `docs/GO.md`, I
approved `.envrc` and used the pinned devbox environment:

```bash
direnv allow
direnv exec . make ci
```

Exact terminal portion:

```text
go vet ./...
golangci-lint run ./...
0 issues.
CGO_ENABLED=1 go test -race -count=1 ./...
?   	github.com/d-cryptic/clickathon/cmd/sonyliv	[no test files]
ok  	github.com/d-cryptic/clickathon/internal/chdb	1.560s
ok  	github.com/d-cryptic/clickathon/internal/config	1.941s
ok  	github.com/d-cryptic/clickathon/internal/otelemit	2.783s
ok  	github.com/d-cryptic/clickathon/internal/pipelinehealth	2.347s
go build  -trimpath -ldflags '-s -w -X main.version=deda6f4' -o bin/sonyliv ./cmd/sonyliv
```

Additional read-only syntax pass:

```text
bash_syntax=PASS files=      32
python_syntax=PASS files=2
```

Verdict: **HOLDS**.

### Claim 2.2 — touched SQL applies cleanly to a scratch database

I created the exact local database `codex_promo_core_70c0`, applied the dependencies and changed SQL in
pipeline order, and installed a trap that dropped only that validated name. It failed at the newly
promoted visualization SQL:

```text
APPLY sql/00_schema.sql ... PASS
APPLY sql/05_landing.sql ... PASS
APPLY sql/10_intervals.sql ... PASS
APPLY sql/12_publish.sql ... PASS
APPLY sql/15_normalise.sql ... PASS
APPLY sql/20_views.sql ... PASS
APPLY sql/30_build_intervals.sql ... PASS
APPLY sql/40_deltas.sql ... PASS
APPLY sql/45_user_concurrency.sql ... PASS
APPLY sql/50_hour_agg.sql ... PASS
APPLY sql/60_projection.sql ... PASS
APPLY sql/80_content.sql ... PASS
APPLY sql/85_windows.sql ... PASS
APPLY sql/87_viz.sql ... FAIL rc=1
Code: 36. DB::Exception: Dictionary (`sonyliv.dict_content`) not found
```

The executable reference is:

```bash
rg -n "dictGet\('sonyliv\.dict_content'" sql/87_viz.sql
```

Exact output:

```text
sql/87_viz.sql:82:    dictGet('sonyliv.dict_content', 'title', tuple(content_id)) AS title,
```

Cleanup verification:

```text
scratch_databases_remaining
0
```

Verdict: **DOES NOT HOLD** — Check 2 requires touched SQL to apply to scratch. The hard-coded graded
dictionary makes `sql/87_viz.sql` non-portable and the clean apply stops before the remaining files.

Overall Check 2 verdict: **DOES NOT HOLD**.

## Check 3 — live read-only claims and accident guards

### Claim 3.1 — target resolution is explicit and typo-safe

With the existing project environment exported, command:

```bash
TARGET=cloud tools/ch "SELECT concat(currentDatabase(), ' ', version())"
TARGET=local tools/ch "SELECT concat(currentDatabase(), ' ', version())"
TARGET=Cloud tools/ch "SELECT currentDatabase()"
```

Exact output:

```text
sonyliv 26.2.1.525
default 26.7.1.1315
tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.
```

Verdict: **HOLDS** for `tools/ch`.

### Claim 3.2 — ordinary graded rebuild and raw-replacement accidents refuse

Commands (the three override variables were explicitly unset, never set):

```bash
env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE TARGET=cloud tools/build-model.sh
env -u REPLACE_GRADED TARGET=cloud tools/load.sh --replace \
  /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-raw-data.csv \
  /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-content-data.csv
```

Exact decisive output:

```text
tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.
rc=1

target=cloud  database=sonyliv  (from CH_DATABASE (environment))  mode=replace
tools/load.sh: REFUSING to --replace the graded database 'sonyliv'.
  This TRUNCATEs sonyliv.ev_raw (905558 rows) and
  sonyliv.content_dim (33464 rows).
rc=1
```

Verdict: **HOLDS**.

### Claim 3.3 — flattening defeats newline formatting and benign SQL remains usable

I supplied read-only `EXPLAIN SYNTAX` statements, so a missed match could not mutate Cloud. Exact
results:

```text
--- benign ---
  /tmp/zshLPGUYo           ... 1
ok
done.
rc=0

--- newline_drop ---
=== apply-sql.sh FAILED ===
/tmp/zshqUjooU contains DROP or TRUNCATE and 'sonyliv' is the GRADED database.
rc=1

--- newline_delete ---
=== apply-sql.sh FAILED ===
/tmp/zshvnXJ1H contains DROP or TRUNCATE and 'sonyliv' is the GRADED database.
rc=1

--- newline_alter_drop ---
=== apply-sql.sh FAILED ===
/tmp/zshIaO97v contains DROP or TRUNCATE and 'sonyliv' is the GRADED database.
rc=1
```

Verdict: **HOLDS** for LF/newline forms and the benign negative control.

### Claim 3.4 — the destructive scanner resists other ordinary formatting

The implementation removes LF and tab, but not CR, and strips only `--` comments, not `/* ... */`.
Running its exact two regular expressions against four inputs produced:

```text
crlf_drop first_regex=1 second_regex=1 normalized_hex=44524f500d205441424c452065765f7261773b
block_comment_drop first_regex=1 second_regex=1 normalized_hex=44524f502f2a2a2f5441424c452065765f7261773b
block_comment_delete first_regex=1 second_regex=1 normalized_hex=44454c4554452f2a2a2f46524f4d2065765f72617720574845524520303b
newline_drop first_regex=0 second_regex=1 normalized_hex=44524f50205441424c452065765f7261773b
```

`0` means matched; both scanner expressions return `1` for CRLF and block-comment forms. Safe Cloud
probes confirm they pass the guard and reach the server instead of producing the guard refusal:

```text
--- crlf_drop ---
  /tmp/zshENkAZo           ... Code: 62. DB::Exception: Syntax error ... TABLE ev_raw ...
FAILED
rc=1

--- block_comment_drop ---
  /tmp/zsho5DdE9           ... Code: 62. DB::Exception: Syntax error ... TABLE ev_raw ...
FAILED
rc=1
```

Those server errors are expected because the safe wrapper is `EXPLAIN SYNTAX`; the important result is
that the scanner did not stop either file. To prove the underlying comment-separated DDL is valid
ClickHouse SQL, I used one uniquely named disposable local Memory table:

```bash
docker exec ch clickhouse-client --database default --multiquery --query \
  $'CREATE TABLE codex_guard_probe_70c0 (x UInt8) ENGINE=Memory;\nDROP/**/TABLE codex_guard_probe_70c0;'
```

Exact output and cleanup check:

```text
block_comment_drop_parse_rc=0 remaining_tables=0
```

A CRLF-separated local `DROP` likewise returned `crlf_drop_parse_rc=0`.

Verdict: **DOES NOT HOLD** — CRLF is a normal file format and block comments are valid SQL formatting.
This is not the acknowledged exported-function attacker bypass; it is the same accidental formatting
threat class as the LF finding. A real destructive statement in either form would be sent to Cloud.

Overall Check 3 verdict: **DOES NOT HOLD**.

## ADR claims on this tree

### ADR 0009 — shared resume rule and deterministic attribution

Command:

```bash
rg -n 'arrayFirst\(x -> x >= p|arrayFilter\(w -> w\.2 > w\.1' \
  sql/30_build_intervals.sql sql/90_reconcile.sql
for file in sql/30_build_intervals.sql sql/40_deltas.sql; do sed 's/--.*//' "$file"; done \
  | rg -c '(^|[^A-Za-z])any\(' || true
```

Exact relevant output:

```text
sql/30_build_intervals.sql:195:            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
sql/30_build_intervals.sql:197:                        if(arrayFirst(x -> x >= p, resumes) = 0,
sql/30_build_intervals.sql:202:                           arrayFirst(x -> x >= p, resumes)),
sql/90_reconcile.sql:116:            arrayFilter(w -> w.2 > w.1, arraySort(arrayMap(
sql/90_reconcile.sql:118:                        if(arrayFirst(x -> x >= p, p2.rs) = 0,
sql/90_reconcile.sql:122:                           arrayFirst(x -> x >= p, p2.rs)),
```

The executable `any()` count is zero. Read-only live measurements:

```text
pause_events	same_second_pause_events	pct
27340	2697	9.86

ev_raw	intervals	delta_rows	hour_rows	peak	peak_minute	hours	user_peak
905558	30323	28073	26254	2917	2026-07-26 10:56:00	1978.1	2844
```

Verdict: **HOLDS** for the current tree and live model. The `>=` rule and zero-length filter are in
both shared-spec implementations, and no executable `any()` remains in interval/delta derivation.

### ADR 0011 — query-time normalization

Read-only live query output:

```text
raw_hin_peak	norm_hin_peak	normalisation_functions	normalisation_views
1774	2196	6	4
```

Verdict: **DOES NOT HOLD** as written, though the mechanism holds. The current tree has the expected
normalization layer and the current live pair is 1,774→2,196. The ADR's first seven lines and
Consequences still claim 1,768→2,180, so its accepted quantitative claim is stale on this combined
tree. `sql/15_normalise.sql` also contains later preprocessing objects whose documentation is omitted.

### ADR 0014 — earliest tied peak minute

Read-only comparison of the stored grand-total hour tier against an independently grouped minute view:

```text
hours_compared	exact	mismatched
98	98	0
```

`tools/unseen-run.sh` also uses `min(peak_minute)` / `min(minute)` at its two submitted-answer sites.
But the absolute ADR rule says earliest wins “at every tier, every grain and every cube level”; this
tree still contains:

```text
sql/90_reconcile.sql:216:            (SELECT argMax(minute, truth) FROM compared),
```

Verdict: **DOES NOT HOLD** for the absolute “everywhere” claim. The serving tier and unseen answer path
hold at 98/98, but the gate's peak sample remains a bare, merge-order-dependent `argMax`, exactly the
site ADR 0014 inventories.

### ADR 0018 — one target, one database

The `tools/ch` probes above **HOLD**. Environment capture is also present in `tools/ch`, `load.sh`,
`apply-sql.sh`, `build-model.sh`, and `reconcile.sh`. However the ADR still states “Resolution rule,
every layer” while its own Known residue admits `load.sh` and `apply-sql.sh` locally fall back to
`CH_DATABASE` when `CH_DATABASE_LOCAL` is absent.

Verdict: **DOES NOT HOLD** for the blanket every-layer/no-cross-target-fallback claim; **HOLDS** for
the five promoted environment-capture paths and the tested explicit `tools/ch` target behavior.

### ADR 0022 — `cube_level` is the structural rollup marker

Static and read-only live output:

```text
sorting_key	cube_level_type	content_minus_one	platform_star	country_star	landing_objects
platform, country, content_id, cube_level, hour	UInt8	0	0	0	0
```

The tree pins `cube_level` through `sql/50_hour_agg.sql`, `sql/85_windows.sql`,
`tools/build-model.sh`, `tools/clickstack-cloud.sh`, and the unseen answer path.

Verdict: **HOLDS** for schema, consumers, and the claim that graded data has zero sentinel collisions.
The manufactured-day measurements are **UNVERIFIABLE** from this candidate because every named
`evidence/unseen/adr-0022-*.txt` proof file is absent.

### ADR 0030 — all-String landing and per-row cast failure

The static tree **HOLDS** for the implementation shape: `sql/05_landing.sql` defines all-String landing
tables, the cast ledger and disposition view; `tools/load.sh` automatically applies it after refusal
guards, lands both files before typing, casts forward, and checks `landed = typed + rejected`.

The accepted empirical proof is not in the candidate:

```text
ABSENT  evidence/landing/identity.txt
ABSENT  docs/codex-validation/004-triage.md
ABSENT  docs/GRADED_INVENTORY.md
```

The read-only live service has `landing_objects=0`, which is expected for data loaded before ADR 0030
but means the Cloud behavior cannot be observed without a prohibited write.

Verdict: implementation wiring **HOLDS**; its claimed 22-assertion identity/corruption/cost proof is
**UNVERIFIABLE** from the promoted tree because the ADR's owned evidence and cited triage document are
omitted.

## Check 4 — correctness gate

The branch and `origin/dev` gate blobs are identical:

```bash
git rev-parse HEAD:sql/90_reconcile.sql origin/dev:sql/90_reconcile.sql
git diff --exit-code HEAD origin/dev -- sql/90_reconcile.sql
```

Exact output:

```text
a353b00f89ec896bee082fc0fcf2d0d806dd7a1c
a353b00f89ec896bee082fc0fcf2d0d806dd7a1c
diff_rc=0
```

I nevertheless ran both blobs independently against Cloud with `readonly=2`.

### Check 4a — `origin/dev` gate

```text
DEV_GATE origin/dev:sql/90_reconcile.sql
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

Verdict: **HOLDS**.

### Check 4b — promoting branch's gate

```text
BRANCH_GATE promo/core sql/90_reconcile.sql
   ┌─ord─┬─scope───┬─c1─────────────────────┬─c2───────────┬─c3─────────────┬─c4────────┬─verdict─┐
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS    │
2. │   2 │ sample  │ 2026-07-14 15:43:00    │ 1            │ 1              │ 0         │ PASS    │
3. │   2 │ sample  │ 2026-07-16 12:35:00    │ 0            │ 0              │ 0         │ PASS    │
4. │   2 │ sample  │ 2026-07-17 08:56:00    │ 0            │ 0              │ 0         │ PASS    │
5. │   2 │ sample  │ 2026-07-26 10:56:00    │ 2917         │ 2917           │ 0         │ PASS    │
6. │   2 │ sample  │ 2026-07-26 11:30:00    │ 197          │ 197            │ 0         │ PASS    │
   └─────┴─────────┴────────────────────────┴──────────────┴────────────────┴───────────┴─────────┘
```

Verdict: **HOLDS**, identically. There is no spec-skew explanation involved.

## Check 5 — independent Codex validation

This file is the independent Codex check. I attacked the copy, closure, scratch, live claims, guards,
ADRs, both gates, and documentation without fixing the candidate.

Verdict: **DOES NOT HOLD** as an approval; this independent review rejects the promotion on multiple
reproduced failures.

## Check 6 — docs current and non-contradictory

### Claim 6.1 — the A5 correction is complete and no equivalent contradiction remains

The corrected A5 itself matches the five promoted capture paths. The same file remains stale around it:

```bash
rg -n 'A1|A2|A5|A6|A8|does not apply `sql/15_normalise|hard-codes|five minutes|never compares' \
  docs/RUNBOOK_UNSEEN.md
```

Relevant exact output:

```text
105:### A1 — the gate's target minutes are 2026-07-26 literals · **breaks silently, reports success**
107:`sql/90_reconcile.sql:24-30` hard-codes five minutes.
114:### A2 — the gate never compares a minute in which nobody was watching
162:### A5 — ~~`CH_DATABASE` in the environment is silently ignored~~ · **FIXED, and inverted**
182:### A6 — `sql/80_content.sql` hard-codes the `sonyliv` database
203:### A8 — "the peak minute" is ambiguous under ties, and the tiers disagree
247:1. **Re-target the gate** (A1).
```

Current tree facts contradict those claims:

```text
sql/90_reconcile.sql:168:    bounds AS
sql/90_reconcile.sql:174:    spine AS
sql/90_reconcile.sql:208:        LEFT JOIN truth_min AS t ON t.minute = sv.minute
tools/build-model.sh:182:... tools/apply-sql.sh sql/15_normalise.sql ...
sql/80_content.sql:332:                dictGet('dict_content', 'title', tuple(content_id)) AS title_raw
```

`sql/90_reconcile.sql` is self-targeting and compares the dense minute spine, `sql/80_content.sql` is
database-relative, the unseen answer path now resolves earliest ties, and `build-model.sh` does apply
normalization. A hard-coded dictionary still exists, but in `sql/87_viz.sql`, not the file the runbook
warns about.

`tools/README.md` also says:

```text
82:does not find it locally, and says so instead of quietly writing to `default`. **`.env.example` does
83:not carry this line yet** (that file is owned elsewhere); add it by hand when you copy it.
85:Not every tool is fixed: `tools/ch`, `reconcile.sh`, `build-model.sh` and `truncation-test.sh` still
86:`cd` to the repo root and let `.env` win, and `tools/ch`'s local branch still has no database
```

But `.env.example:19` is exactly `CH_DATABASE_LOCAL=default`, and the tested `tools/ch`, build, and
reconcile scripts capture the caller's environment before sourcing `.env`.

Verdict: **DOES NOT HOLD**.

### Claim 6.2 — promoted docs resolve to the files/evidence they cite

Command and exact output:

```text
ABSENT  docs/adr/0012-rebuild-owns-every-tier-and-the-last-any-leaves.md
ABSENT  docs/adr/0016-publisher-owns-the-user-and-hour-tiers.md
ABSENT  docs/adr/0025-fail-open-preprocessing-and-row-quality.md
ABSENT  queries/validate_source_contract.sql
ABSENT  evidence/target-resolution.txt
ABSENT  evidence/tie-break-determinism.txt
ABSENT  evidence/landing/identity.txt
ABSENT  evidence/unseen/adr-0022-sentinel-collision.txt
ABSENT  docs/codex-validation/004-triage.md
ABSENT  docs/GRADED_INVENTORY.md
ABSENT  docs/PREPROCESSING.md
```

Each path is referenced by an ADR, promoted SQL, or a promoted tool. Most exist on `origin/dev`; they
were simply left out of this increment.

`docs/GO.md` has another current-tree contradiction: it states `make lint` refuses anything but
golangci-lint 2.12.2, while this branch's `Makefile` invokes `golangci-lint run` directly. The actual
version guard exists in `origin/dev:Makefile`, not here. The ambient v1 run reached the tool's own
schema error rather than the documented repo refusal.

Verdict: **DOES NOT HOLD**.

Overall Check 6 verdict: **DOES NOT HOLD**.

## Closure audit

| Check | Verdict | Decisive result |
|---|---|---|
| 1 · isolate/coherence | **DOES NOT HOLD** | Mandatory source-contract, benchmark, robustness, and accepted-proof files are absent; unseen path is broken. |
| 2 · build/test/scratch | **DOES NOT HOLD** | Pinned CI passes; clean scratch SQL fails at hard-coded `sonyliv.dict_content`. |
| 3 · real/read-only claims | **DOES NOT HOLD** | Live figures reproduce, but CRLF and block-comment destructive SQL bypass the graded scanner. |
| 4a · deployed gate | **HOLDS** | 17,028 · 0 · 0 · 2,917. |
| 4b · branch gate | **HOLDS** | Byte-identical gate; identical 17,028 · 0 · 0 · 2,917. |
| 5 · independent validation | **DOES NOT HOLD** | This review rejects the candidate. |
| 6 · docs current | **DOES NOT HOLD** | Runbook, tools README, Go docs, ADR numbers, and cited paths contradict or exceed this tree. |

**DO NOT PROMOTE** — the combined increment is still not a runnable coherent state: required source-contract/benchmark/robustness files are absent, and its promoted visualization SQL cannot apply to scratch because it hard-codes the graded dictionary.
