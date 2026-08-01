# CODEX Check 5 — Wave A Tooling File-State Promotion
> **Summary:** **DO NOT PROMOTE.** The branch is exactly one commit above `main`, but the file-state-copy claim does not hold.
> Of the ten non-evidence paths in the wave, nine are byte-identical to `origin/dev`; `tools/load.sh` differs by 353 insertions and 37 deletions.
> The tooling is not separable from SQL: promoted `tools/build-model.sh` unconditionally applies absent `sql/15_normalise.sql`; current dev's loader also requires absent `sql/05_landing.sql`.
> The six newly named destructive forms are blocked on one line, but ordinary newline formatting defeats all of them and also defeats `DROP`/`TRUNCATE`.
> `make ci`, all four target-resolution probes, both ordinary graded guards, 4a (`17,028 / 0 / 0 / 2,917`) and the expected 4b skew (`17,028 / 177 / 39 / 2,887`) hold.
> Check 6 fails because `docs/RUNBOOK_UNSEEN.md` still says caller environment is ignored, contradicting all four promoted environment-capture scripts.

Validated 2026-08-02 on branch `promo/w12-fileset` at `97ac096`. Verdict words below use the required
**HOLDS**, **DOES NOT HOLD**, and **UNVERIFIABLE** vocabulary.

## Safety record

`REBUILD_GRADED`, `REPLACE_GRADED`, and `APPLY_GRADED_DESTRUCTIVE` were never given an authorising
value. No `INSERT`, `TRUNCATE`, `ALTER`, `CREATE`, `DROP`, or `OPTIMIZE` reached database `sonyliv`.
All correctness and routing queries against it were read-only.

One validation mistake must be recorded rather than hidden. I selected `sql/70_truncation_test.sql`
for an expected destructive-scanner refusal without first reading that file. The scanner correctly
allowed it because it contains only `CREATE` / `CREATE OR REPLACE`, and the command applied twice:

```text
$ env -u APPLY_GRADED_DESTRUCTIVE -u GRADED_DB TARGET=cloud tools/apply-sql.sh sql/70_truncation_test.sql
applying to CLOUD: <CH_HOST>/sonyliv   (database from CH_DATABASE (environment))
  sql/70_truncation_test.sql ... ok
done.
[exit 0]

$ env -u APPLY_GRADED_DESTRUCTIVE GRADED_DB=anything TARGET=cloud tools/apply-sql.sh sql/70_truncation_test.sql
applying to CLOUD: <CH_HOST>/sonyliv   (database from CH_DATABASE (environment))
  sql/70_truncation_test.sql ... ok
done.
[exit 0]
```

This violated the no-Cloud-write boundary even though it did not write the graded database. Every
executable write in that 343-line file is explicitly qualified to `sonyliv_trunc`; its own lines
18–22 state that `sonyliv` is SELECT-only. A read-only `system.query_log` check showed the two runs at
22:39:52–22:40:05 UTC as `Create` statements naming `sonyliv_trunc.*`; the subsequent deployed-spec
gate remained exactly green. No cleanup was attempted because this review owns no external mutation
and destructive cleanup was prohibited.

## Step zero — branch identity

Exact command and output:

```text
$ git fetch origin
[exit 0; no output]
$ git checkout promo/w12-fileset
Switched to branch 'promo/w12-fileset'
Your branch is ahead of 'main' by 1 commit.
  (use "git push" to publish your local commits)
$ git log --oneline -3
97ac096 promote: target resolution and the graded-database guards (wave A — tooling)
2b551b5 docs: record what main was before any feature was promoted
c10e97d docs: correct every stale claim in the submission artifacts (Q27)
```

Exact ancestry command and output:

```text
$ git merge-base HEAD main
2b551b59b398da3ec82ca784c039c2520f5c7980
$ git rev-parse main
2b551b59b398da3ec82ca784c039c2520f5c7980
$ git rev-list --count main..HEAD
1
```

**Verdict: HOLDS.** The branch is off `main` at `2b551b5` with exactly one promotion commit. No
`dev` merge is present.

## Check 1 — isolate a coherent file set

### Claim: all ten wave paths equal dev's versions

Exact command (tree-object equality, so timestamps and working-copy metadata are irrelevant):

```bash
git diff --name-only main..HEAD | grep -v '^evidence/' |
while IFS= read -r file_path; do
  head_oid=$(git rev-parse --verify "HEAD:${file_path}")
  dev_oid=$(git rev-parse --verify "origin/dev:${file_path}")
  if [ "$head_oid" = "$dev_oid" ]; then verdict=IDENTICAL; else verdict=DIFFERS; fi
  printf '%-9s %s\n' "$verdict" "$file_path"
done
printf 'tooling_path_count='
git diff --name-only main..HEAD | grep -v '^evidence/' | wc -l | tr -d ' '
```

Exact output:

```text
IDENTICAL .env.example
IDENTICAL docs/GO.md
IDENTICAL docs/adr/0018-one-target-one-database-no-cross-target-fallback.md
IDENTICAL internal/config/config.go
IDENTICAL internal/config/config_test.go
IDENTICAL tools/apply-sql.sh
IDENTICAL tools/build-model.sh
IDENTICAL tools/ch
DIFFERS   tools/load.sh
IDENTICAL tools/reconcile.sh
tooling_path_count=10
```

The eleventh changed path, `evidence/reconcile.txt`, is also byte-identical to `origin/dev`.

Exact size and timing of the mismatch:

```text
$ git diff --numstat HEAD..origin/dev -- tools/load.sh
353	37	tools/load.sh
$ git show -s --format='%h %cI %s' 97ac096 c54d9dc
97ac096 2026-08-02T03:58:59+05:30 promote: target resolution and the graded-database guards (wave A — tooling)
c54d9dc 2026-08-02T04:03:12+05:30 merge: an all-String landing table so one bad row costs a row, not the file (Y1, ADR 0030)
```

`origin/dev` moved four minutes after this promotion commit. The branch neither matches current dev
nor records a pinned dev tree for its equality claim.

**Verdict: DOES NOT HOLD.** `tools/load.sh` is not dev's version.

### Claim: the tooling wave is separable from `sql/`

Exact command and output:

```text
$ git diff --name-status main..HEAD -- sql/
[exit 0; no output]
$ rg -n 'sql/15_normalise.sql' tools/build-model.sh
182:TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/15_normalise.sql >/dev/null
$ git cat-file -e HEAD:sql/15_normalise.sql 2>/dev/null
[exit 128]
$ git cat-file -e origin/dev:sql/15_normalise.sql 2>/dev/null
[exit 0]
```

The promoted build script reaches line 182 unconditionally after five write stages. Therefore a
normal `make model` on this branch mutates/rebuilds tiers and then fails because the required file is
absent. CI cannot see this runtime shell/file dependency.

There is a second incompatibility if the stale loader is replaced with current dev's version:

```text
$ git show origin/dev:tools/load.sh | rg -n 'sql/05_landing.sql'
49:# Schema: sql/05_landing.sql. This script applies it itself before landing a
560:[ -f "$LANDING_SQL" ] || die "cannot find sql/05_landing.sql next to $0.
595:  TARGET=cloud tools/apply-sql.sh --database $DB sql/05_landing.sql"
$ git cat-file -e HEAD:sql/05_landing.sql 2>/dev/null
[exit 128]
$ git cat-file -e origin/dev:sql/05_landing.sql 2>/dev/null
[exit 0]
```

Thus the wave has no coherent choice: its checked-in loader is stale, while dev's current loader
requires a SQL file outside the wave.

**Verdict: DOES NOT HOLD.** The promoted tooling already requires absent model SQL, and completing
the dev file copy introduces another absent SQL dependency.

## Check 2 — build and test

Exact command:

```bash
devbox run -- make ci
```

Exact output (dependency downloads included by the clean shell):

```text
Info: Running script "make" on /Users/barun/.superconductor/worktrees/clickathon-project/sc-charged-squid-42b2
Info: Ensuring packages are installed.
go mod tidy
go: downloading github.com/ClickHouse/clickhouse-go/v2 v2.47.0
go: downloading go.opentelemetry.io/otel/trace v1.44.0
go: downloading go.yaml.in/yaml/v3 v3.0.4
go: downloading github.com/shopspring/decimal v1.4.0
go: downloading github.com/ClickHouse/ch-go v0.73.0
go: downloading github.com/google/uuid v1.6.0
go: downloading github.com/andybalholm/brotli v1.2.1
go: downloading github.com/paulmach/orb v0.13.0
go: downloading go.opentelemetry.io/otel v1.44.0
go: downloading github.com/stretchr/testify v1.11.1
go: downloading gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405
go: downloading github.com/xyproto/randomstring v1.0.5
go: downloading github.com/segmentio/asm v1.2.1
go: downloading github.com/klauspost/compress v1.18.6
go: downloading github.com/go-faster/errors v0.7.1
go: downloading github.com/go-faster/city v1.0.1
go: downloading github.com/pierrec/lz4/v4 v4.1.27
go: downloading gopkg.in/yaml.v3 v3.0.1
go: downloading github.com/pmezard/go-difflib v1.0.0
go: downloading github.com/davecgh/go-spew v1.1.1
go: downloading golang.org/x/sys v0.46.0
go: downloading github.com/google/go-cmp v0.7.0
go: downloading github.com/cespare/xxhash/v2 v2.3.0
go vet ./...
golangci-lint run ./...
0 issues.
CGO_ENABLED=1 go test -race -count=1 ./...
?   	github.com/d-cryptic/clickathon/cmd/sonyliv	[no test files]
?   	github.com/d-cryptic/clickathon/internal/chdb	[no test files]
ok  	github.com/d-cryptic/clickathon/internal/config	2.268s
ok  	github.com/d-cryptic/clickathon/internal/otelemit	1.918s
ok  	github.com/d-cryptic/clickathon/internal/pipelinehealth	1.534s
go build  -trimpath -ldflags '-s -w -X main.version=97ac096' -o bin/sonyliv ./cmd/sonyliv
[exit 0]
```

The branch changes no SQL, so no branch-owned SQL was eligible for a scratch apply. The runtime
missing-file defect above remains a Check-1 coherence failure; `make ci` does not run `make model`.

**Verdict: HOLDS.** Tidy, vet, lint, race tests, and build all pass.

## Check 3 — run target resolution for real

This worktree has no `.env`. The established project checkout's `.env` was sourced into the process
without copying or printing it, then the required invocations were run verbatim.

Exact commands and outputs:

```text
$ TARGET=cloud tools/ch "SELECT currentDatabase(), version()"
sonyliv	26.2.1.525
[exit 0]
$ tools/ch -c "SELECT currentDatabase(), version()"
sonyliv	26.2.1.525
[exit 0]
$ tools/ch "SELECT currentDatabase(), version()"
default	26.7.1.1315
[exit 0]
$ TARGET=Cloud tools/ch "SELECT currentDatabase(), version()"
tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.
[exit 1]
```

**Verdict: HOLDS.** Both Cloud spellings resolve to `sonyliv` 26.2.1.525; the bare command resolves
to local `default` 26.7.1.1315; invalid casing dies without local fallback.

## Guard claims

Each live refusal probe used the same non-printing credential preamble as Check 3:

```bash
set -a
source /Users/barun/Developers/personal/clickathon-project/.env
set +a
```

### `build-model.sh` refuses, including `GRADED_DB=anything`

Exact commands and outputs:

```text
$ env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE TARGET=cloud tools/build-model.sh
tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.

  This truncates session_intervals, cc_user_minute, cc_minute_delta and
  cc_hour_agg on the service we are scored on, then rebuilds them from ev_raw.
  If your working tree is on a stale base, the rebuild writes STALE SQL over
  correct answers and the result looks plausible. That has happened once.

  Before you override, confirm all three:
    1. git log --oneline -1        is a commit you meant to build from
    2. git status --porcelain      is clean
    3. you actually intend to replace the graded answers

  Then:  REBUILD_GRADED=yes TARGET=cloud tools/build-model.sh

  For any other purpose use a scratch database — sql/70_truncation_test.sql
  shows the pattern — or run without TARGET=cloud for local.
[exit 1]

$ env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE GRADED_DB=anything TARGET=cloud tools/build-model.sh
tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.

  This truncates session_intervals, cc_user_minute, cc_minute_delta and
  cc_hour_agg on the service we are scored on, then rebuilds them from ev_raw.
  If your working tree is on a stale base, the rebuild writes STALE SQL over
  correct answers and the result looks plausible. That has happened once.

  Before you override, confirm all three:
    1. git log --oneline -1        is a commit you meant to build from
    2. git status --porcelain      is clean
    3. you actually intend to replace the graded answers

  Then:  REBUILD_GRADED=yes TARGET=cloud tools/build-model.sh

  For any other purpose use a scratch database — sql/70_truncation_test.sql
  shows the pattern — or run without TARGET=cloud for local.
[exit 1]
```

**Verdict: HOLDS.** Both ordinary caller input and the previous `GRADED_DB` bypass refuse before the
first model write.

### `load.sh --replace` refuses, including `GRADED_DB=anything`

Exact commands used the delivered CSV paths. Both produced the same refusal after read-only shape,
existence, and count checks:

```text
$ env -u REPLACE_GRADED TARGET=cloud tools/load.sh --replace /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-raw-data.csv /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-content-data.csv
target=cloud  database=sonyliv  (from CH_DATABASE (environment))  mode=replace
header shape: ev_raw <- /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-raw-data.csv
  all 13 expected columns present, in the expected order
header shape: content_dim <- /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-content-data.csv
  all 4 expected columns present, in the expected order

tools/load.sh: REFUSING to --replace the graded database 'sonyliv'.

  This TRUNCATEs sonyliv.ev_raw (905558 rows) and
  sonyliv.content_dim (33464 rows). ev_raw is the raw event stream
  every served answer is derived from, and unlike the model tiers it CANNOT be
  rebuilt — it can only be re-loaded from the CSV, if you still have it.

  Both graded-database incidents were recoverable precisely because ev_raw was
  untouched. This is the operation that would remove that safety net.

  If you genuinely intend to reload the graded raw data:
    REPLACE_GRADED=yes TARGET=cloud tools/load.sh --replace ...

  For anything else, target a scratch database:  --database <name>
[exit 1]

$ env -u REPLACE_GRADED GRADED_DB=anything TARGET=cloud tools/load.sh --replace /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-raw-data.csv /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-content-data.csv
target=cloud  database=sonyliv  (from CH_DATABASE (environment))  mode=replace
header shape: ev_raw <- /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-raw-data.csv
  all 13 expected columns present, in the expected order
header shape: content_dim <- /Users/barun/Developers/personal/clickathon-project/data/ch-hackathon-content-data.csv
  all 4 expected columns present, in the expected order

tools/load.sh: REFUSING to --replace the graded database 'sonyliv'.

  This TRUNCATEs sonyliv.ev_raw (905558 rows) and
  sonyliv.content_dim (33464 rows). ev_raw is the raw event stream
  every served answer is derived from, and unlike the model tiers it CANNOT be
  rebuilt — it can only be re-loaded from the CSV, if you still have it.

  Both graded-database incidents were recoverable precisely because ev_raw was
  untouched. This is the operation that would remove that safety net.

  If you genuinely intend to reload the graded raw data:
    REPLACE_GRADED=yes TARGET=cloud tools/load.sh --replace ...

  For anything else, target a scratch database:  --database <name>
[exit 1]
```

**Verdict: HOLDS.** The loader's fixed `readonly GRADED_DB=sonyliv` subject is not defeated by the
old environment override.

### The six newly named destructive forms

This in-memory probe is the exact two grep predicates from `tools/apply-sql.sh:187-188`; it sends no
SQL anywhere. Exact command:

```bash
scan_probe() {
  label="$1"
  sql="$2"
  if printf "%s" "$sql" | sed 's/--.*//' |
       grep -qiE '(^|[[:space:];])(DROP|TRUNCATE|DETACH|RENAME[[:space:]]+TABLE|EXCHANGE[[:space:]]+TABLES|REPLACE[[:space:]]+TABLE|DELETE[[:space:]]+FROM|OPTIMIZE)[[:space:]]' \
     || printf "%s" "$sql" | sed 's/--.*//' |
       grep -qiE 'ALTER[[:space:]]+TABLE[^;]*(DELETE|UPDATE|DROP[[:space:]]+(COLUMN|PARTITION)|CLEAR[[:space:]]+COLUMN|MOVE[[:space:]]+PARTITION|REPLACE[[:space:]]+PARTITION|MATERIALIZE[[:space:]]+TTL|MODIFY[[:space:]]+COLUMN)'; then
    printf '%-35s BLOCKED\n' "$label"
  else
    printf '%-35s MISSED\n' "$label"
  fi
}
scan_probe 'DELETE FROM one-line' 'DELETE FROM ev_raw WHERE 1'
scan_probe 'OPTIMIZE one-line' 'OPTIMIZE TABLE ev_raw FINAL'
scan_probe 'MOVE PARTITION one-line' 'ALTER TABLE ev_raw MOVE PARTITION tuple() TO TABLE sink'
scan_probe 'REPLACE PARTITION one-line' 'ALTER TABLE ev_raw REPLACE PARTITION tuple() FROM source'
scan_probe 'MATERIALIZE TTL one-line' 'ALTER TABLE ev_raw MATERIALIZE TTL'
scan_probe 'MODIFY COLUMN one-line' 'ALTER TABLE ev_raw MODIFY COLUMN user_id String'
```

Exact output:

```text
DELETE FROM one-line                BLOCKED
OPTIMIZE one-line                   BLOCKED
MOVE PARTITION one-line             BLOCKED
REPLACE PARTITION one-line          BLOCKED
MATERIALIZE TTL one-line            BLOCKED
MODIFY COLUMN one-line              BLOCKED
```

**Verdict: HOLDS for the six canonical one-line spellings.** Each newly listed statement matches the
broadened predicate.

### General question: can ordinary valid SQL formatting still pass this accident guard?

The same exact function was rerun with only whitespace changed at a keyword boundary. Exact calls:

```bash
scan_probe 'DROP newline TABLE' $'DROP\nTABLE ev_raw'
scan_probe 'TRUNCATE newline TABLE' $'TRUNCATE\nTABLE ev_raw'
scan_probe 'DELETE newline FROM' $'DELETE\nFROM ev_raw WHERE 1'
scan_probe 'OPTIMIZE newline TABLE' $'OPTIMIZE\nTABLE ev_raw FINAL'
scan_probe 'MOVE newline PARTITION' $'ALTER TABLE ev_raw MOVE\nPARTITION tuple() TO TABLE sink'
scan_probe 'REPLACE newline PARTITION' $'ALTER TABLE ev_raw REPLACE\nPARTITION tuple() FROM source'
scan_probe 'MATERIALIZE newline TTL' $'ALTER TABLE ev_raw MATERIALIZE\nTTL'
scan_probe 'MODIFY newline COLUMN' $'ALTER TABLE ev_raw MODIFY\nCOLUMN user_id String'
```

Exact output:

```text
DROP newline TABLE                  MISSED
TRUNCATE newline TABLE              MISSED
DELETE newline FROM                 MISSED
OPTIMIZE newline TABLE              MISSED
MOVE newline PARTITION              MISSED
REPLACE newline PARTITION           MISSED
MATERIALIZE newline TTL             MISSED
MODIFY newline COLUMN               MISSED
```

These are valid ClickHouse statements, not theoretical token strings. A read-only local parser check
normalized representative inputs as follows:

```text
DELETE
FROM ev_raw WHERE user_id = 'x'
DELETE FROM ev_raw WHERE user_id = 'x'
OPTIMIZE
TABLE ev_raw FINAL
OPTIMIZE TABLE ev_raw FINAL
ALTER TABLE ev_raw MOVE
PARTITION tuple() TO TABLE ev_raw_sink
ALTER TABLE ev_raw
    (MOVE PARTITION tuple() TO TABLE ev_raw_sink)
ALTER TABLE ev_raw MODIFY
COLUMN user_id String
ALTER TABLE ev_raw
    (MODIFY COLUMN `user_id` String)
```

The regression is visible directly in the implementation: unlike the earlier reviewed predicate,
the current scanner never joins lines before `grep`. Newline formatting is normal generated or
hand-formatted SQL and does not require function shadowing, conditional sourcing, or a determined
operator. It is inside the stated accident threat model.

**Verdict: DOES NOT HOLD.** The destructive scanner remains bypassable by ordinary valid formatting.

### Scope disagreement, not used as the sole rejection

The general form of the earlier question is broader: *can a normal repo-owned invocation change
`sonyliv` without any graded acknowledgement?* The answer remains yes. Running the exact guard
predicate over branch SQL reports these answer-changing files as allowed:

```text
ALLOW    sql/30_build_intervals.sql                 INSERT
ALLOW    sql/40_deltas.sql                          INSERT
ALLOW    sql/45_user_concurrency.sql                CREATE,INSERT,REPLACE
ALLOW    sql/50_hour_agg.sql                        CREATE,INSERT,REPLACE
```

Their executable inserts begin at lines 61, 45, 111, and 113 respectively. Therefore a stale direct
`TARGET=cloud tools/apply-sql.sh sql/30_build_intervals.sql` is allowed even though stale direct
application is the accident class described in the guard comments. `tools/ch` also deliberately
forwards arbitrary SQL, and `load.sh --append` deliberately inserts without a graded-specific
acknowledgement.

I agree that exported-function and conditional-source tricks are out of scope. I disagree that
plain direct `apply-sql.sh` INSERT/CREATE belongs outside an accident boundary: it requires no shell
trick, and a stale branch is one of the stated threats. Per the brief, this scope disagreement is not
the sole reason for rejection; the file mismatch, missing SQL dependency, and multiline scanner gap
are independent failures.

## Check 4 — correctness gate

Before execution, comment-stripped scans of both gate files returned
`READ_ONLY_SCAN_CLEAR` for `INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|OPTIMIZE|RENAME|REPLACE|DETACH|ATTACH|EXCHANGE`.

### 4a — dev's deployed-spec gate

Exact command:

```bash
dev_gate="$(git show origin/dev:sql/90_reconcile.sql)"
tools/ch -c "$dev_gate"
```

Exact output:

```text
0	SUMMARY	minutes_compared=17028	mismatched=0	max_abs_diff=0	peak=2917	PASS
2	sample	2026-07-14 15:43:00	1	1	0	PASS
2	sample	2026-07-16 12:35:00	0	0	0	PASS
2	sample	2026-07-17 08:56:00	0	0	0	PASS
2	sample	2026-07-26 10:56:00	2917	2917	0	PASS
2	sample	2026-07-26 11:30:00	197	197	0	PASS
```

**Verdict: HOLDS.** The live graded database matches its deployed dev spec over all 17,028 minutes,
with zero mismatches, max absolute difference zero, and peak 2,917.

### 4b — this branch's own gate

Exact command:

```bash
branch_gate="$(sed -n '1,9999p' sql/90_reconcile.sql)"
tools/ch -c "$branch_gate"
```

Exact output:

```text
0	SUMMARY	minutes_compared=17028	mismatched=177	max_abs_diff=39	peak=2887	MISMATCH
1	MISMATCH	2026-07-26 10:47:00	2526	2554	28	MISMATCH
1	MISMATCH	2026-07-26 10:52:00	2730	2758	28	MISMATCH
1	MISMATCH	2026-07-26 10:55:00	2833	2860	27	MISMATCH
1	MISMATCH	2026-07-26 10:56:00	2887	2917	30	MISMATCH
1	MISMATCH	2026-07-26 10:57:00	2854	2885	31	MISMATCH
1	MISMATCH	2026-07-26 10:58:00	2828	2855	27	MISMATCH
1	MISMATCH	2026-07-26 10:59:00	2857	2890	33	MISMATCH
1	MISMATCH	2026-07-26 11:00:00	2836	2873	37	MISMATCH
1	MISMATCH	2026-07-26 11:01:00	2826	2865	39	MISMATCH
1	MISMATCH	2026-07-26 11:02:00	2810	2846	36	MISMATCH
1	MISMATCH	2026-07-26 11:03:00	2771	2803	32	MISMATCH
1	MISMATCH	2026-07-26 11:04:00	2763	2789	26	MISMATCH
1	MISMATCH	2026-07-26 11:05:00	2703	2732	29	MISMATCH
1	MISMATCH	2026-07-26 11:06:00	2650	2679	29	MISMATCH
1	MISMATCH	2026-07-26 11:07:00	2612	2645	33	MISMATCH
1	MISMATCH	2026-07-26 11:08:00	2535	2571	36	MISMATCH
1	MISMATCH	2026-07-26 11:09:00	2512	2547	35	MISMATCH
1	MISMATCH	2026-07-26 11:10:00	2450	2483	33	MISMATCH
1	MISMATCH	2026-07-26 11:11:00	2358	2386	28	MISMATCH
1	MISMATCH	2026-07-26 11:12:00	2296	2324	28	MISMATCH
2	sample	2026-07-14 15:43:00	1	1	0	PASS
2	sample	2026-07-16 12:35:00	0	0	0	PASS
2	sample	2026-07-17 08:56:00	0	0	0	PASS
2	sample	2026-07-26 10:56:00	2887	2917	30	MISMATCH
2	sample	2026-07-26 11:30:00	193	197	4	MISMATCH
```

The branch changes no model SQL: `git diff --name-status main..HEAD -- sql/` is empty. This is exactly
the known `main`/deployed-spec skew attributed to dev commit `0c0f020`; there is no additional row,
count, magnitude, or peak deviation from the stated expected result.

**Verdict: HOLDS under the Wave-A rule.** The 177 mismatches are expected spec skew and are not a
Wave-A defect.

## Check 5 — independent cross-model validation

This report is the requested Codex validation. It re-derived all outcomes from the checked-out tree
and live read-only queries rather than accepting the promotion commit's claims.

**Verdict: DOES NOT HOLD overall.** The independent review found multiple promotion-blocking defects.

## Check 6 — docs current

The branch's unseen-day runbook still describes the pre-fix behavior:

```text
$ nl -ba docs/RUNBOOK_UNSEEN.md | sed -n '162,169p'
162 ### A5 — `CH_DATABASE` in the environment is silently ignored
163
164 Every tool does `[ -f .env ] && set -a && . ./.env && set +a`, so `.env` **overwrites** anything
165 passed in the environment. `CH_DATABASE=sonyliv_unseen tools/build-model.sh` writes to **`sonyliv`**.
166 All of `build-model.sh`, `reconcile.sh`, `apply-sql.sh` and `truncation-test.sh` also `cd` to the repo
167 root first, so they always read the repo's `.env`. **The only way to point them at another database is
168 to edit `.env`.** `tools/load.sh` is the one exception (it does not `cd`), which is why
169 `tools/unseen-run.sh` runs it from a sandbox directory holding an overridden `.env`.
```

That directly contradicts the promoted implementations. For example:

```text
tools/build-model.sh:48:ENV_DB="${CH_DATABASE-}"
tools/build-model.sh:50:[ -f .env ] && set -a && . ./.env && set +a
tools/build-model.sh:51:[ -n "$ENV_DB" ] && export CH_DATABASE="$ENV_DB"
tools/reconcile.sh:23:ENV_DB="${CH_DATABASE-}"
tools/reconcile.sh:26:[ -n "$ENV_DB" ] && export CH_DATABASE="$ENV_DB"
tools/apply-sql.sh:49:ENV_DB="${CH_DATABASE-}"
tools/load.sh:88:ENV_DB="${CH_DATABASE-}"
```

`origin/dev` has a substantially rewritten `docs/RUNBOOK_UNSEEN.md`; it was omitted from this
file-owned wave even though the wave changes exactly the behavior its A5 section documents.

**Verdict: DOES NOT HOLD.** A user following the promoted branch's runbook would edit `.env`
unnecessarily and would be told that the now-working scratch environment override is dangerous and
ignored.

## Overall verdicts

| Claim/check | Verdict | Result |
|---|---|---|
| Branch is one commit off `main` | **HOLDS** | `97ac096` over `2b551b5` |
| Ten wave paths equal dev | **DOES NOT HOLD** | `tools/load.sh` differs `+353/-37` |
| Tooling wave is SQL-separable | **DOES NOT HOLD** | `build-model.sh` requires absent `sql/15_normalise.sql`; current dev loader requires absent `sql/05_landing.sql` |
| Check 2 `make ci` | **HOLDS** | exit 0; tidy, vet, lint, race tests, build |
| Target routing | **HOLDS** | Cloud `sonyliv` 26.2.1.525; local `default` 26.7.1.1315; bad target dies |
| Build guard and old `GRADED_DB` bypass | **HOLDS** | both exit 1 before a stage |
| Replace guard and old `GRADED_DB` bypass | **HOLDS** | both exit 1 at 905,558 / 33,464 rows |
| Six new one-line scanner forms | **HOLDS** | all six blocked |
| General destructive-SQL scanner | **DOES NOT HOLD** | eight valid multiline forms missed |
| 4a deployed-spec gate | **HOLDS** | `17,028 / 0 / 0 / 2,917` |
| 4b branch gate attribution | **HOLDS** | exact known `17,028 / 177 / 39 / 2,887` skew |
| Check 6 docs current | **DOES NOT HOLD** | unseen runbook contradicts promoted env precedence |

**DO NOT PROMOTE — the promoted build path unconditionally requires absent `sql/15_normalise.sql`, so Wave A is not a coherent file-separable state.**
