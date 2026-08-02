# CODEX check 5 — `promo/core`, second look
> **Summary:** **DO NOT PROMOTE.** The combined increment is still not a coherent runnable state.
> Check 1 **DOES NOT HOLD**: `promotion-deps.sh` reports COHERENT while required runtime assets are absent.
> The copy claim **DOES NOT HOLD**: only 60 of the stated 64 copied files match the fetched `dev` state.
> Check 2 **DOES NOT HOLD**: `make ci` passes, but clean scratch apply still fails in `sql/87_viz.sql`.
> Check 3 **DOES NOT HOLD**: the candidate retains CRLF/block-comment bypasses; the third revision also misses `#` comments.
> Checks 4a/4b **HOLD** identically at 17,028 · 0 · 0 · 2,917; ADR 0014 and Check 6 **DO NOT HOLD**.

Validated 2026-08-02 from `c757be6767cf29a1dcfb240859998c88a4ec30d1`, against the Step Zero
base `2b551b59b398da3ec82ca784c039c2520f5c7980` and fetched `dev` snapshot
`daf1edee00c266f7e9b2f17a570519cb8df18729`. The shared refs advanced during the run to
`origin/main=61bfa87ee14e67bab04d4ea1b369f74e41bc7543` and
`origin/dev=c642066027cfd4deb6e19d0ca25ebb40f75433f4`; the 64-file comparison was repeated
against that later `dev` and returned the same 60/4 split.

I made no product fix and changed only this report. The pre-existing untracked
`sqlite_mcp_server.db` was not touched. Cloud access was SELECT-only; no INSERT, TRUNCATE, ALTER,
CREATE, DROP or OPTIMIZE was sent to Cloud. `REBUILD_GRADED`, `REPLACE_GRADED` and
`APPLY_GRADED_DESTRUCTIVE` remained unset. One exactly named local scratch database was created,
used for Check 2, dropped, and verified absent.

Per the repository's official ClickHouse guidance, Cloud discovery and queries followed
`agent-connect-mcp`, `agent-discovery-schema` and `agent-query-safety`: bounded result sets,
execution timeouts and explicit scan caps. The gate needed a 100-million-row scan cap; a
10-million cap stopped safely at 10.10 million rows before returning a verdict.

## Step Zero and immutable scope

Command:

```bash
sc worktree status --json
git status --short --branch
git fetch origin
git checkout promo/core
git log --oneline -2
```

Exact decisive output:

```text
{"kind":"worktree_status","response":{"branch":"chore/promo-core-validation","target_branch":"main","files_changed":1,"insertions":0,"deletions":0}}
## chore/promo-core-validation
?? sqlite_mcp_server.db
Switched to a new branch 'promo/core'
branch 'promo/core' set up to track 'origin/promo/core'.
c757be6 promote: add queries/validate_source_contract.sql — the gate shipped without its SQL
8dd6e42 docs: Codex check-5 verdict on promo/core (DO NOT PROMOTE)
```

Ancestry command:

```bash
git rev-list --left-right --count 2b551b5...HEAD
git log --oneline 2b551b5..HEAD
```

Exact output:

```text
0       3
c757be6 promote: add queries/validate_source_contract.sql — the gate shipped without its SQL
8dd6e42 docs: Codex check-5 verdict on promo/core (DO NOT PROMOTE)
deda6f4 promote: the model and the tooling that runs it (core increment)
```

Verdict: **DOES NOT HOLD** — the supplied “off main, one commit” setup claim is false. The product
increment is one commit (`deda6f4`), but the candidate ref contains that increment, the prior rejected
report, and the latest SQL addition. This history discrepancy is not the promotion-blocking finding;
the resulting tree fails independently below.

I read the six checks with:

```bash
git show daf1edee00c266f7e9b2f17a570519cb8df18729:docs/PROMOTION.md
```

Verdict: **HOLDS** — the required promotion procedure was read from the fetched `dev` snapshot. No
merge from `dev` was performed.

## Check 1 — isolate, copy and dependency closure

### Claim 1.1 — all 64 copied files match `dev`

The original 64-copy set is `deda6f4`'s files excluding its deliberate runbook edit and the old
Codex report. Exact command:

```bash
dev_snapshot=daf1edee00c266f7e9b2f17a570519cb8df18729
copy_total=0; copy_same=0; copy_different=0
while IFS= read -r copied_file; do
  copy_total=$((copy_total+1))
  if git cat-file -e "${dev_snapshot}:$copied_file" 2>/dev/null &&
     [ "$(git rev-parse "HEAD:$copied_file")" =
       "$(git rev-parse "${dev_snapshot}:$copied_file")" ]; then
    copy_same=$((copy_same+1))
  else
    printf 'DIFFERS %s\n' "$copied_file"
    copy_different=$((copy_different+1))
  fi
done < <(git diff-tree --no-commit-id --name-only -r deda6f4 |
         rg -v '^(docs/RUNBOOK_UNSEEN\.md|docs/codex-validation/004\.md)$')
printf 'same=%d different=%d total=%d\n' "$copy_same" "$copy_different" "$copy_total"
```

Exact output:

```text
DIFFERS sql/87_viz.sql
DIFFERS tools/README.md
DIFFERS tools/apply-sql.sh
DIFFERS tools/unseen-run.sh
same=60 different=4 total=64
```

Repeated after `origin/dev` advanced to `c642066`:

```text
DIFFERS sql/87_viz.sql
DIFFERS tools/README.md
DIFFERS tools/apply-sql.sh
DIFFERS tools/unseen-run.sh
latest_dev_same=60 different=4 total=64
```

The newly added query does match both trees:

```bash
git rev-parse HEAD:queries/validate_source_contract.sql
git rev-parse daf1edee:queries/validate_source_contract.sql
```

```text
46d3fe020baa86e87b8de64d408972df4077c6a6
46d3fe020baa86e87b8de64d408972df4077c6a6
```

Diffstat for the four stale copies:

```bash
git diff --stat HEAD..daf1edee -- \
  sql/87_viz.sql tools/apply-sql.sh tools/README.md tools/unseen-run.sh
```

```text
 sql/87_viz.sql      |   9 +++-
 tools/README.md     |   1 +
 tools/apply-sql.sh  |  10 +++-
 tools/unseen-run.sh | 128 ++++++++++++++++++++++++++++++++++++++++++++++------
 4 files changed, 131 insertions(+), 17 deletions(-)
```

Verdict: **DOES NOT HOLD** — the query addition is correct, but four of the 64 files no longer match
the fetched `dev` state. Those are not incidental files: they contain the claimed scratch fix, the
claimed scanner fix, the Q37 unseen-runner agreement fix, and a tooling-catalogue update.

### Claim 1.2 — `promotion-deps.sh` proves the candidate coherent

The checker itself is absent from the candidate:

```bash
test -f tools/promotion-deps.sh && echo PRESENT || echo 'HEAD tools/promotion-deps.sh: ABSENT'
```

```text
HEAD tools/promotion-deps.sh: ABSENT
```

I executed the fetched `dev` version, removing only its `cd` because it was streamed rather than
materialised under `tools/`:

```bash
git show daf1edee:tools/promotion-deps.sh |
  sed '/^cd "$(dirname "$0")\/\.\."$/d' |
  bash -s -- promo/core 2b551b59b398da3ec82ca784c039c2520f5c7980
```

Exact output:

```text
candidate promo/core carries 68 files


COHERENT — every referenced file that differs from 2b551b59b398da3ec82ca784c039c2520f5c7980 is carried.
```

That green result is false. Required candidate/dev/base states:

```bash
for dependency_path in \
  evidence/liveness/vocabulary.tsv \
  evidence/benchmark \
  evidence/query-robustness \
  evidence/landing/identity.txt; do
  # print tree existence at HEAD, dev snapshot and base
done
```

Exact output:

```text
evidence/liveness/vocabulary.tsv HEAD=ABSENT DEV=PRESENT BASE=ABSENT
evidence/benchmark               HEAD=ABSENT DEV=PRESENT BASE=ABSENT
evidence/query-robustness        HEAD=ABSENT DEV=PRESENT BASE=ABSENT
evidence/landing/identity.txt    HEAD=ABSENT DEV=PRESENT BASE=ABSENT
```

They are real references:

```bash
rg -n 'BENCH_DIR=|RB=evidence/query-robustness|VOCAB=|identity.txt' \
  tools/bench.sh tools/query-robustness.sh tools/validate-source-contract.sh \
  tools/landing-test.sh sql/05_landing.sql
```

Relevant exact output:

```text
tools/bench.sh:20:BENCH_DIR=evidence/benchmark
tools/query-robustness.sh:34:RB=evidence/query-robustness
tools/validate-source-contract.sh:37:VOCAB="$ROOT/evidence/liveness/vocabulary.tsv"
tools/landing-test.sh:38:OUT=evidence/landing/identity.txt
sql/05_landing.sql:258:-- That identity is proven, not asserted: evidence/landing/identity.txt.
```

The promoted source-contract tool now has its SQL, but still cannot run:

```bash
env -u REBUILD_GRADED -u REPLACE_GRADED -u APPLY_GRADED_DESTRUCTIVE \
  TARGET=cloud tools/validate-source-contract.sh -c --database sonyliv
```

Exact output:

```text
validate-source-contract: missing /Users/barun/.superconductor/worktrees/clickathon-project/sc-cooled-dewar-1f71/evidence/liveness/vocabulary.tsv — the vocabulary contract is half the gate (doubts/11)
rc=2
```

Why the checker misses this, from its own lines 29–44:

```text
case "$f" in *.md|evidence/*|docs/*) continue ;; esac
grep -oE '\b(sql|tools|queries|internal|cmd)/[A-Za-z0-9_./-]+'
[ -f "$r" ] || continue
git diff --quiet "$BASE" dev -- "$r" 2>/dev/null && continue
```

There are three independent under-reporting mechanisms:

1. The extractor does not include the `evidence/` prefix, so it cannot see the vocabulary file,
   benchmark directory, robustness directory, or ADR proof targets.
2. `[ -f "$r" ]` intentionally discards directories. Here that hides two real runtime input trees,
   `evidence/benchmark` and `evidence/query-robustness`; they are not Go import paths.
3. It checks the working tree filesystem and mutable local `dev`, not `BR:<path>` and the fetched
   `origin/dev` snapshot. During this run `dev` moved from `daf1edee` to `c642066`, yet the tool has
   no parameter or output showing which `dev` it used.

Verdict: **DOES NOT HOLD** — `COHERENT` is a false positive. The source-contract gate demonstrably
exits 2 before any query, the benchmark runner lacks every benchmark SQL/params file, and the
query-robustness runner lacks its cases, fixtures, shapes, truths, comparator and invariants.

### Claim 1.3 — SQL cross-file closure is runnable

All changed SQL plus unchanged prerequisites were applied in pipeline order to the exact local
database `codex_promo_core_1f71`. Preflight first proved it did not exist; cleanup dropped only that
validated name and then counted remaining databases with that name.

Command shape:

```bash
scratch_db=codex_promo_core_1f71
docker exec -i ch clickhouse-client --database default \
  --query "SELECT count() FROM system.databases WHERE name = '$scratch_db' FORMAT TSVRaw"
docker exec -i ch clickhouse-client --database default --query "CREATE DATABASE $scratch_db"
for sql_file in sql/00_schema.sql sql/05_landing.sql sql/10_intervals.sql \
  sql/12_publish.sql sql/15_normalise.sql sql/20_views.sql \
  sql/30_build_intervals.sql sql/40_deltas.sql sql/45_user_concurrency.sql \
  sql/50_hour_agg.sql sql/60_projection.sql sql/80_content.sql sql/85_windows.sql \
  sql/87_viz.sql sql/90_reconcile.sql; do
  CH_DATABASE_LOCAL="$scratch_db" TARGET=local \
    tools/apply-sql.sh --database "$scratch_db" "$sql_file"
done
docker exec -i ch clickhouse-client --database default --query \
  "DROP DATABASE codex_promo_core_1f71"
```

Exact result summary:

```text
scratch_preflight name=codex_promo_core_1f71 existing=0
APPLY sql/00_schema.sql              PASS
APPLY sql/05_landing.sql             PASS
APPLY sql/10_intervals.sql           PASS
APPLY sql/12_publish.sql             PASS
APPLY sql/15_normalise.sql           PASS
APPLY sql/20_views.sql               PASS
APPLY sql/30_build_intervals.sql     PASS
APPLY sql/40_deltas.sql              PASS
APPLY sql/45_user_concurrency.sql    PASS
APPLY sql/50_hour_agg.sql            PASS
APPLY sql/60_projection.sql          PASS
APPLY sql/80_content.sql             PASS
APPLY sql/85_windows.sql             PASS
APPLY sql/87_viz.sql                 FAIL rc=1
Code: 36. DB::Exception: Dictionary (`sonyliv.dict_content`) not found
APPLY sql/90_reconcile.sql           PASS
scratch_apply_failures=1
scratch_cleanup remaining=0
```

Verdict: **DOES NOT HOLD** — SQL closure still fails in the same file as the first review. The fix
exists on `dev`; it was not copied onto this candidate.

Overall Check 1 verdict: **DOES NOT HOLD**.

## Check 2 — build, tests and scratch SQL

### Claim 2.1 — pinned CI is green

Command:

```bash
direnv allow
direnv exec . make ci
```

Exact terminal output:

```text
go vet ./...
golangci-lint run ./...
0 issues.
CGO_ENABLED=1 go test -race -count=1 ./...
?    github.com/d-cryptic/clickathon/cmd/sonyliv [no test files]
ok   github.com/d-cryptic/clickathon/internal/chdb
ok   github.com/d-cryptic/clickathon/internal/config
ok   github.com/d-cryptic/clickathon/internal/otelemit
ok   github.com/d-cryptic/clickathon/internal/pipelinehealth
go build -trimpath -ldflags '-s -w -X main.version=c757be6' -o bin/sonyliv ./cmd/sonyliv
```

Auxiliary syntax pass, scoped to files present in the immutable candidate diff:

```text
bash_syntax files=25 failures=0
python_syntax files=2 failures=0
```

Verdict: **HOLDS**.

### Claim 2.2 — touched SQL applies to a clean scratch database

Command and exact output are recorded under Claim 1.3.

Verdict: **DOES NOT HOLD** — `sql/87_viz.sql` still reads the graded database's dictionary.

Overall Check 2 verdict: **DOES NOT HOLD**.

## Check 3 — live read-only claims and accident guards

### Claim 3.1 — target resolution and ordinary graded guards refuse safely

The project `.env` was sourced in-process without printing values. All override variables were
explicitly removed from each environment.

Commands:

```bash
env -u REBUILD_GRADED -u REPLACE_GRADED -u APPLY_GRADED_DESTRUCTIVE \
  TARGET=cloud tools/build-model.sh
env -u REBUILD_GRADED -u REPLACE_GRADED -u APPLY_GRADED_DESTRUCTIVE \
  TARGET=cloud tools/load.sh --replace <raw.csv> <content.csv>
env -u REBUILD_GRADED -u REPLACE_GRADED -u APPLY_GRADED_DESTRUCTIVE \
  TARGET=Cloud tools/ch "SELECT 1 LIMIT 1"
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

tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.
rc=1
```

Verdict: **HOLDS** for these three entry points. Neither graded guard needed or received an override.

### Claim 3.2 — `sql/87_viz.sql` is unqualified; all siblings are comments

Command:

```bash
rg -n 'sonyliv\.' sql
```

Exact candidate output:

```text
sql/80_content.sql:32:--     dictGet('sonyliv.dict_content', 'title', tuple(content_id))
sql/60_projection.sql:35:-- never from the text. An earlier version hard-coded `sonyliv.`, which made the file
sql/87_viz.sql:82:    dictGet('sonyliv.dict_content', 'title', tuple(content_id)) AS title,
sql/70_truncation_test.sql:32:-- Mirror of sonyliv.ev_raw. Same engine, same sort key, same settings — the
```

After stripping `/*…*/` and `--` comments, exact output:

```text
82:    dictGet('sonyliv.dict_content', 'title', tuple(content_id)) AS title,
FILE sql/87_viz.sql
```

On the fetched `dev` snapshot, comment-stripped output is empty. Raw `dev` matches are four comments,
in `sql/60_projection.sql`, `sql/70_truncation_test.sql`, `sql/80_content.sql` and `sql/87_viz.sql`.

Verdict: **DOES NOT HOLD** on the candidate — `sql/87_viz.sql` is still executable and qualified.
The substantive sibling claim **HOLDS** on `dev`, but there are three sibling files, not two; all
three are comments.

### Claim 3.3 — the third-revision scanner catches ordinary formatting

I ran the exact candidate normalizer and the exact `dev` normalizer against in-memory fixtures. No
fixture was written to a file or sent to Cloud.

Exact output:

```text
current crlf_drop                BYPASS norm=<DROP\r TABLE ev_raw;>
dev     crlf_drop                BLOCK  norm=<DROP TABLE ev_raw;>
current block_delete             BYPASS norm=<DELETE/* ordinary */FROM ev_raw WHERE 1;>
dev     block_delete             BLOCK  norm=<DELETE FROM ev_raw WHERE 1;>
current hash_comment_delete      BYPASS norm=<DELETE # ordinary comment FROM ev_raw WHERE 1;>
dev     hash_comment_delete      BYPASS norm=<DELETE # ordinary comment FROM ev_raw WHERE 1;>
current quoted_hyphen_then_drop  BYPASS norm=<SELECT '>
dev     quoted_hyphen_then_drop  BYPASS norm=<SELECT '>
current benign                   BYPASS norm=<SELECT 'DROP TABLE is text';>
dev     benign                   BYPASS norm=<SELECT 'DROP TABLE is text';>
```

Local read-only parser proof that ClickHouse treats `#` as a line comment:

```bash
docker exec -i ch clickhouse-client --database default --query \
  $'EXPLAIN SYNTAX SELECT 1 # ordinary comment\n + 1 SETTINGS max_execution_time=5'
```

```text
SELECT plus(1, 1)
FROM system.one
SETTINGS max_execution_time = 5
```

The third ordinary bypass is therefore:

```sql
DELETE # ordinary explanation
FROM ev_raw WHERE ...;
```

ClickHouse removes the `#` line comment and parses `DELETE FROM`; the scanner preserves the comment,
flattens the newline, and misses `DELETE FROM`. The scanner is also not quote-aware:
`SELECT '--'; DROP TABLE ev_raw;` is valid multi-statement SQL, but its line-comment stripping leaves
only `SELECT '`, hiding the later DROP.

Verdict: **DOES NOT HOLD**. On this candidate, the previous CRLF and block-comment bypasses remain
because the revision was not copied. Even `dev`'s third revision has the `#` and quoted-literal
bypasses. These are ordinary parser forms, not exported-function shadowing.

Overall Check 3 verdict: **DOES NOT HOLD**.

## ADR claims against this tree

### ADR 0009 — inclusive resume and deterministic attribution

Command:

```bash
rg -n 'arrayFirst\(x -> x (>|>=) p|w\.2 > w\.1' \
  sql/30_build_intervals.sql sql/90_reconcile.sql
rg -n '(^|[^A-Za-z])any\(' sql/30_build_intervals.sql sql/40_deltas.sql
```

Relevant exact output:

```text
sql/30_build_intervals.sql:195:arrayFilter(w -> w.2 > w.1, ...
sql/30_build_intervals.sql:197:arrayFirst(x -> x >= p, resumes)
sql/30_build_intervals.sql:202:arrayFirst(x -> x >= p, resumes)
sql/90_reconcile.sql:116:arrayFilter(w -> w.2 > w.1, ...
sql/90_reconcile.sql:118:arrayFirst(x -> x >= p, p2.rs)
sql/90_reconcile.sql:122:arrayFirst(x -> x >= p, p2.rs)
```

The `any()` search returns comments only; no executable `any()` remains in either file. Live
read-only state:

```bash
tools/ch -c "SELECT count(), round(sum(dateDiff('second', interval_start, interval_end))/3600,1)
             FROM session_intervals FINAL"
```

```text
30323   1978.1
```

Verdict: **HOLDS** — `>=` and the zero-length filter are in both shared-spec files, and the last
pipeline `any()` is gone.

### ADR 0011 — normalization artifact and wiring

Commands:

```bash
sed -n '1,379p' sql/15_normalise.sql | rg -c '^CREATE (OR REPLACE )?FUNCTION'
sed -n '1,379p' sql/15_normalise.sql | rg -c '^CREATE (OR REPLACE )?VIEW'
rg -n 'apply sql/15_normalise\.sql' tools/build-model.sh
```

Exact output:

```text
normalisation_lane_functions=6
normalisation_lane_views=4
tools/build-model.sh:182:apply sql/15_normalise.sql >/dev/null
```

The whole file, after later preprocessing additions, contains 9 functions and 8 views. Live
read-only peaks are:

```text
raw Hindi peak        1774
normalized Hindi peak 2196
```

Verdict: **DOES NOT HOLD** as a current-tree ADR. It says “five UDFs”, says both three and four
views, and labels build wiring “NOT APPLIED”; this tree has six normalization functions, four
normalization views, and `build-model.sh` applies the file. The behavior itself is deployed and the
current 1,774 → 2,196 result holds; the ADR's current-state inventory does not.

### ADR 0014 — earliest peak minute everywhere

The hour/day path agrees with earliest-wins live:

```bash
tools/ch -c "SELECT count() AS days,
  countIf(d.peak != m.peak OR d.peak_minute != m.peak_minute) AS mismatched
FROM v_concurrency_day_total AS d
INNER JOIN
(
  SELECT toDate(minute) AS day, max(concurrent) AS peak,
         argMax(minute, (concurrent, -toInt64(toUInt32(minute)))) AS peak_minute
  FROM v_concurrency_minute_delta_total GROUP BY day
) AS m USING (day)"
```

```text
7       0
```

But the ADR explicitly owns the gate sample and says it changed from bare `argMax`. Current tree:

```bash
sed -n '210,219p' sql/90_reconcile.sql
```

```text
samples AS
(
    SELECT arrayJoin([
        (SELECT argMax(minute, truth) FROM compared),
        (SELECT min(minute) FROM compared),
        (SELECT max(minute) FROM compared),
```

Verdict: **DOES NOT HOLD** — the serving day view is correct, but ADR 0014's “earliest everywhere”
and reproducible gate-evidence claims are false. The bare gate sample is verdict-neutral on today's
unique global peak, but becomes arbitrary on a tied unseen day.

### ADR 0018 — one target, one database, every layer

Shell typo refusal is verified under Claim 3.1. Go's environment resolver is different:

```go
func TargetFromEnv() Target {
    if strings.EqualFold(os.Getenv("TARGET"), string(TargetCloud)) {
        return TargetCloud
    }
    return TargetLocal
}
```

`cmdVerify` and `cmdObserve` use this as the flag default. Therefore `TARGET=Cloud` becomes Cloud in
Go while shell rejects it, and any other non-empty typo silently becomes local before
`config.Load` can reject an unknown value. The tests cover only unset and exact lowercase `cloud`.

Verdict: **DOES NOT HOLD** — the exact host/database resolution code and CI tests hold, but the ADR's
“TARGET is read on every layer and an unrecognised value dies” claim is false in the Go entry point.
The ADR also still states blanket “every layer” language while RUNBOOK A5 says that language was
withdrawn in favor of a measured per-layer table.

### ADR 0022 — `cube_level` is structural

Static command:

```bash
rg -n 'cube_level' sql/50_hour_agg.sql sql/85_windows.sql \
  tools/build-model.sh tools/unseen-run.sh tools/unseen-verify.sh
```

Relevant exact output:

```text
sql/50_hour_agg.sql:129:    cube_level  UInt8,
sql/50_hour_agg.sql:143:ORDER BY (platform, country, content_id, cube_level, hour)
sql/50_hour_agg.sql:168:INSERT INTO cc_hour_agg (... cube_level ...)
sql/50_hour_agg.sql:226:PARTITION BY lv_platform, lv_country, lv_content_id, cube_level, hour
sql/85_windows.sql:513:argMax(peak_minute, ...) AS pk_min,
tools/build-model.sh:160:HOUR_HAS_CUBE_LEVEL=...
tools/unseen-run.sh:418:... content_id=-1 AND cube_level=0
```

Cloud discovery and sentinel audit:

```text
cc_hour_agg cube_level UInt8
sorting_key = platform, country, content_id, cube_level, hour
content_minus_one=0 platform_star=0 country_star=0
```

Verdict: **HOLDS** for the structural implementation and live no-collision claim. The ADR's named
proof `evidence/unseen/adr-0022-sentinel-collision.txt` is absent from this candidate, so its
historical rehearsal measurements are **UNVERIFIABLE from the promoted tree**.

### ADR 0030 — all-String landing boundary

Static implementation evidence:

```text
sql/05_landing.sql:68:CREATE TABLE IF NOT EXISTS ev_landing
sql/05_landing.sql:108:CREATE TABLE IF NOT EXISTS content_landing
sql/05_landing.sql:146:CREATE TABLE IF NOT EXISTS ev_cast_quarantine
tools/load.sh:629:# PHASE A — LAND. Both files, as text, before either typed table is touched.
tools/load.sh:745:# THE DISPOSITION PROOF. Every landed row reached exactly one terminal state
tools/load.sh:767:rollback_and_die "the disposition check ..."
```

`sql/05_landing.sql` and the full load/build dependency chain applied successfully to the clean
scratch database before `sql/87_viz.sql` failed.

Verdict: **HOLDS** for the tree's landing, cast-ledger, ordering, rollback and disposition structure.
The 22-assertion proof and historical cost/fingerprint claims are **UNVERIFIABLE from the promoted
tree** because `evidence/landing/identity.txt` is absent.

Promoted ADR proof-target inventory:

```text
ABSENT  evidence/tie-break-determinism.txt
ABSENT  evidence/target-resolution.txt
ABSENT  evidence/unseen/adr-0022-sentinel-collision.txt
ABSENT  evidence/landing/identity.txt
```

Overall ADR verdict: **DOES NOT HOLD** — ADR 0009 and the structural halves of 0022/0030 hold, but
0011's current inventory/wiring, 0014's gate claim, and 0018's every-layer target claim contradict
this tree. Four named proof artifacts are also omitted.

## Check 4 — two live correctness measurements

Cloud discovery was SELECT-only and found the expected deployed shape:

```text
sonyliv  26.2.1.525
cc_hour_agg       SharedReplacingMergeTree    26254
cc_minute_delta   SharedAggregatingMergeTree  28073
cc_user_minute    SharedReplacingMergeTree    91692
ev_raw            SharedMergeTree             905558
session_intervals SharedReplacingMergeTree    30323
```

The branch and fetched-dev gate blobs are identical:

```bash
git rev-parse HEAD:sql/90_reconcile.sql
git rev-parse daf1edee:sql/90_reconcile.sql
```

```text
a353b00f89ec896bee082fc0fcf2d0d806dd7a1c
a353b00f89ec896bee082fc0fcf2d0d806dd7a1c
```

Both were nevertheless executed separately. Exact command shape, with the file's terminal semicolon
removed only so safety settings remain part of the same HTTP statement:

```bash
gate_sql="$(git show <ref>:sql/90_reconcile.sql | sed '$s/;[[:space:]]*$//')"
env -u REBUILD_GRADED -u REPLACE_GRADED -u APPLY_GRADED_DESTRUCTIVE \
  TARGET=cloud tools/ch "$gate_sql SETTINGS max_execution_time=30,
    max_rows_to_read=100000000, max_result_rows=100,
    timeout_before_checking_execution_speed=0"
```

Check 4a exact output (`daf1edee` gate):

```text
0 SUMMARY minutes_compared=17028 mismatched=0 max_abs_diff=0 peak=2917 PASS
2 sample 2026-07-14 15:43:00 1 1 0 PASS
2 sample 2026-07-16 12:35:00 0 0 0 PASS
2 sample 2026-07-17 08:56:00 0 0 0 PASS
2 sample 2026-07-26 10:56:00 2917 2917 0 PASS
2 sample 2026-07-26 11:30:00 197 197 0 PASS
```

Check 4b exact output (`c757be6` gate):

```text
0 SUMMARY minutes_compared=17028 mismatched=0 max_abs_diff=0 peak=2917 PASS
2 sample 2026-07-14 15:43:00 1 1 0 PASS
2 sample 2026-07-16 12:35:00 0 0 0 PASS
2 sample 2026-07-17 08:56:00 0 0 0 PASS
2 sample 2026-07-26 10:56:00 2917 2917 0 PASS
2 sample 2026-07-26 11:30:00 197 197 0 PASS
```

Verdict 4a: **HOLDS**.

Verdict 4b: **HOLDS** — identical, with no skew to explain.

Overall Check 4 verdict: **HOLDS**.

## Check 5 — independent cross-lineage validation

This file is Check 5. It records commands, outputs, safety boundaries and per-claim verdicts without
changing product code.

Verdict: **HOLDS** as an executed review; its promotion verdict is negative.

## Check 6 — documentation is current and non-contradictory

RUNBOOK A5 itself is corrected:

```text
### A5 — ~~`CH_DATABASE` in the environment is silently ignored~~ · **FIXED, and inverted**
**The environment now WINS.**
```

Verdict for the narrow A5 correction: **HOLDS**.

The same contradiction remains elsewhere. `tools/README.md` first says:

```text
`load.sh` and `apply-sql.sh` obey `--database`, then the environment, then `.env`,
and refuse rather than guess.
```

but later says:

```text
Not every tool is fixed: `tools/ch`, `reconcile.sh`, `build-model.sh` and
`truncation-test.sh` still `cd` to the repo root and let `.env` win, and
`tools/ch`'s local branch still has no database parameter at all ...
```

That later statement is false for promoted `tools/ch`, `reconcile.sh` and `build-model.sh` and makes
the file contradict its own summary. Additional current-status contradictions:

```text
WALKTHROUGH.md:181:| `CH_DATABASE` env var silently ignored | — | **BROKEN** — a retarget appears to work and writes to production |
docs/EXPLAINER.md:577:| 13 | A CSV reload **doubles** the data · `CH_DATABASE` silently ignored | ... | open |
docs/EXPLAINER.md:825:**`CH_DATABASE` is silently ignored**
```

`docs/SESSION-2026-08-01.md` also names the old defect, but it is a historical session record and is
not counted as a contradiction. WALKTHROUGH and EXPLAINER are current-state documents and are.

The RUNBOOK also says ADR 0018's “every layer” claim was withdrawn and replaced by a measured
per-layer table, while the promoted ADR still says:

```text
Decision: ... both always sent explicitly ... missing config dies at startup.
Resolution rule, every layer:
```

The ADR 0011/0014 contradictions and four absent proof targets are documented above.

Verdict: **DOES NOT HOLD** — A5 is corrected locally, but the same current-state contradiction
survives in tools/README, WALKTHROUGH and EXPLAINER, and two promoted ADRs contradict executable code.

## Closure

| Check | Verdict | Decisive evidence |
|---|---|---|
| 1 · isolate/coherence | **DOES NOT HOLD** | false-green dependency checker; required assets absent; copy is 60/64 |
| 2 · build/test/scratch | **DOES NOT HOLD** | CI green; `sql/87_viz.sql` still fails scratch apply |
| 3 · live/guards | **DOES NOT HOLD** | ordinary guards hold; scanner and source-contract path fail |
| 4a · deployed gate | **HOLDS** | 17,028 · 0 · 0 · 2,917 |
| 4b · candidate gate | **HOLDS** | identical 17,028 · 0 · 0 · 2,917 |
| 5 · Codex validation | **HOLDS** | this evidence file |
| 6 · docs current | **DOES NOT HOLD** | current docs and ADRs contradict the promoted tree |

**DO NOT PROMOTE — `promo/core` is not runnable: `promotion-deps.sh` reports COHERENT while the source-contract vocabulary and benchmark/robustness runtime input trees are absent.**
