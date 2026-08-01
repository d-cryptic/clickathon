# Codex re-validation — W1 foundations

> **Summary:** **DO NOT PROMOTE.** Plain environment, subshell and `declare -g` probes are fixed,
> but exported-function and conditional-source routes still defeat both guards without authorization.
> The scanner misses valid destructive SQL. Check 4a passes **17,028 / 0 / 0 / 2,917**; 4b fails **17,028 / 177 / 39 / 2,887**.
> ADR 0011, ADR 0014, and **2,887 -> 2,917 / 1,949.3 -> 1,978.1 h** survive; ADR 0018 is narrowed.
> Check 1 and docs also fail: the tip carries an unrelated empty database and touched docs contradict the tree.

Validated 2026-08-02 on macOS with GNU bash 3.2.57. The checked-out remote branch moved during this
review from the requested fix commit `618b9c6` to `c81c93a`; the latter adds only an empty
`sqlite_mcp_server.db`, so the guard implementation under review remains the one from `618b9c6`.

No write was sent to ClickHouse Cloud or database `sonyliv`. `REBUILD_GRADED` and
`APPLY_GRADED_DESTRUCTIVE` were never set. Every guard-bypass probe used `guard-test.invalid` plus
exported failing `curl`/`docker` stubs. Per the vendored `agent-query-safety` rule, agent-generated
live SELECTs used explicit result limits, scan caps, and execution timeouts; the repo's Go verifier
used its 30-second context deadline. I did not run `make model`,
`publish.sh`, an unstubbed `build-model.sh`, or any Cloud
INSERT/TRUNCATE/ALTER/CREATE/DROP/OPTIMIZE.

## Verdicts

| Claim/check | Verdict | Fresh result |
|---|---|---|
| 1 · isolated coherent W1 branch | **DOES NOT HOLD** | Tip includes unrelated `c81c93a` and empty `sqlite_mcp_server.db`; current `origin/main` is not an ancestor. |
| 2 · `make ci` | **HOLDS** | Tidy, vet, lint (`0 issues`), race tests, and build exit 0. |
| 3 · target resolution works live | **HOLDS** | Shell and Go resolve Cloud to `sonyliv`, local to `default`; invalid `TARGET=Cloud` dies. |
| `readonly GRADED_DB=sonyliv` fixes caller override | **DOES NOT HOLD** | Plain variable mechanisms are fixed, but exported-function and conditional-source routes still preserve the caller's subject and reach destructive execution. |
| destructive-file scanner covers the destructive path | **DOES NOT HOLD** | It misses `DELETE FROM`, `MOVE PARTITION`, `REPLACE PARTITION`, `MATERIALIZE TTL`, `OPTIMIZE ... CLEANUP`, and `MODIFY COLUMN`. |
| ADR 0018 no longer claims every layer implements the rule | **HOLDS** | The claim is explicitly withdrawn and replaced by a measured per-layer table. |
| 4a · deployed-spec gate | **HOLDS** | 17,028 compared; 0 mismatched; max absolute difference 0; peak 2,917. |
| 4b · this branch's own gate | **DOES NOT HOLD** | 17,028 compared; 177 mismatched; max absolute difference 39; peak 2,887. The brief says any mismatch is failure. |
| ADR 0011 live objects and Hindi pair | **HOLDS** | Five UDFs, four views, correct behavior, 1,774 -> 2,196 (+422, +23.8%). |
| ADR 0014 live hour tier and views | **HOLDS** | 98/98 hours agree; 0 bare live-view `argMax(minute, ...)`. |
| headline before/after | **HOLDS** | Old derivation: 30,769 / 1,949.3 h and peak 2,887; live: 30,323 / 1,978.1 h and peak 2,917. |
| 6 · docs current | **DOES NOT HOLD** | `docs/RUNBOOK_UNSEEN.md` says the derived-sample gate still uses date literals; `docs/GO.md` says Go and shell cannot disagree while ADR 0018 documents that they can. |

## 1 · Branch identity and isolation

Exact command:

```bash
git rev-parse origin/dev
git rev-parse origin/main
git rev-parse origin/chore/promotion-w1-foundations
git log --oneline -6
```

Exact output:

```text
e425adc238c4535db5f481fa7c7871e5e687aef9
2b551b59b398da3ec82ca784c039c2520f5c7980
c81c93a4fe52c169cd2d1e5349a4e3b9ff850dca
c81c93a wip: overnight preservation checkpoint
618b9c6 fix: a guard whose subject the caller controls is not a guard (W1 check 5)
cd0010b docs: confirm make ci green at the final W1 branch state
0cd4199 docs: prove the check-4 spec skew by isolation — two characters account for all 177 minutes
64f2ed7 docs: W1 stops at check 4 again — the rebuild deployed a wave-2 spec the branch does not carry
7551e1f docs: W1 promotion stops at check 4 — the graded database fails its own gate
```

Exact command:

```bash
git merge-base --is-ancestor origin/main HEAD
printf 'origin_main_is_ancestor_exit=%s\n' "$?"
git rev-list --count origin/main..HEAD
git diff --name-only 618b9c6..HEAD
git ls-tree -l HEAD sqlite_mcp_server.db
```

Exact output:

```text
origin_main_is_ancestor_exit=1
9
sqlite_mcp_server.db
100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391       0	sqlite_mcp_server.db
```

`origin/main` has one commit (`2b551b5`) after the branch point `c10e97d`; the feature branch does
not contain it. More importantly, `c81c93a` is explicitly an unreviewed preservation commit and the
zero-byte SQLite file is unrelated to W1 foundations.

**Verdict: DOES NOT HOLD.** The requested fix is identifiable, but the current branch tip is not the
minimal coherent W1 set that should be promoted.

## 2 · Build and test

Exact command:

```bash
devbox run -- make ci
```

Exact output:

```text
Info: Running script "make" on /Users/barun/.superconductor/worktrees/clickathon-project/sc-frozen-cuprate-e464
go mod tidy
go vet ./...
golangci-lint run ./...
level=warning msg="[runner] Can't process results by generated_file_filter processor: can't filter issue &result.Issue{FromLinter:\"goconst\", Text:\"string `abc.clickhouse.cloud` has 3 occurrences, make it a constant\", Severity:\"\", SourceLines:[]string(nil), Pkg:(*packages.Package)(0xa3a796591e0), Pos:token.Position{Filename:\"/Users/barun/.superconductor/worktrees/clickathon-project/sc-condensed-meissner-6502/internal/config/config_test.go\", Offset:929, Line:26, Column:55}, LineRange:(*result.Range)(nil), HunkPos:0, SuggestedFixes:[]analysis.SuggestedFix(nil), ExpectNoLint:false, ExpectedNoLintLinter:\"\", WorkingDirectoryRelativePath:\"../sc-condensed-meissner-6502/internal/config/config_test.go\", RelativePath:\"../sc-condensed-meissner-6502/internal/config/config_test.go\"}: failed to get doc (lax) of file /Users/barun/.superconductor/worktrees/clickathon-project/sc-condensed-meissner-6502/internal/config/config_test.go: failed to parse file: open /Users/barun/.superconductor/worktrees/clickathon-project/sc-condensed-meissner-6502/internal/config/config_test.go: no such file or directory"
0 issues.
CGO_ENABLED=1 go test -race -count=1 ./...
?   	github.com/d-cryptic/clickathon/cmd/sonyliv	[no test files]
?   	github.com/d-cryptic/clickathon/internal/chdb	[no test files]
ok  	github.com/d-cryptic/clickathon/internal/config	1.402s
ok  	github.com/d-cryptic/clickathon/internal/otelemit	1.717s
ok  	github.com/d-cryptic/clickathon/internal/pipelinehealth	2.044s
go build  -trimpath -ldflags '-s -w -X main.version=c81c93a' -o bin/sonyliv ./cmd/sonyliv
```

Exit was 0. The warning is a stale linter-cache reference to a deleted sibling worktree; the linter
still reports `0 issues`. W1 changes no SQL model file, so there is no branch-owned schema statement
to apply to scratch for this check.

**Verdict: HOLDS.**

## 3 · Run the target-resolution feature for real

Exact command (the Cloud host is redacted by the command before output):

```bash
set -a
source /Users/barun/Developers/personal/clickathon-project/.env
set +a
TARGET=cloud tools/ch "SELECT currentDatabase() AS database, version() AS version LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
TARGET=local tools/ch "SELECT currentDatabase() AS database, version() AS version LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
CH_DATABASE_LOCAL=system TARGET=local tools/ch "SELECT currentDatabase() AS database LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
TARGET=Cloud tools/ch "SELECT 1 LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
```

Exact output:

```text
database	version
sonyliv	26.2.1.525
database	version
default	26.7.1.1315
database
system
tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.
```

The non-default local `system` probe proves `tools/ch` sent the environment's explicit local
database instead of merely getting the server default by coincidence.

Exact Go command:

```bash
./bin/sonyliv verify -target cloud -timeout 30s | sed -E 's|^(server[[:space:]]+[^@]+)@.*$|\1@ <CH_HOST>:<CH_PORT>|' | sed -n '1,4p'
./bin/sonyliv verify -target local -timeout 30s | sed -n '1,4p'
```

Exact output:

```text
target   cloud
server   26.2.1.525 @ <CH_HOST>:<CH_PORT>
database sonyliv (user default)

target   local
server   26.7.1.1315 @ localhost:8123
database default (user app)
```

**Verdict: HOLDS.** The layers that ADR 0018 now claims as complete work against both live targets.

## 4 · The `readonly GRADED_DB` fix

### Plain environment, subshell and `declare -g`

Exact command:

```bash
env GRADED_DB=scratch bash -c 'set -euo pipefail; readonly GRADED_DB=sonyliv; printf "env_prefix value=%s attrs=%s\n" "$GRADED_DB" "$(declare -p GRADED_DB)"'
bash -c 'set -u; readonly GRADED_DB=sonyliv; if (GRADED_DB=scratch); then printf "subshell_assignment=accepted\n"; else printf "subshell_assignment=rejected outer=%s\n" "$GRADED_DB"; fi'
bash -c 'set -u; readonly GRADED_DB=sonyliv; if declare -g GRADED_DB=scratch; then printf "declare_global=accepted\n"; else printf "declare_global=rejected value=%s\n" "$GRADED_DB"; fi'
```

Exact output:

```text
env_prefix value=sonyliv attrs=declare -rx GRADED_DB="sonyliv"
bash: line 1: GRADED_DB: readonly variable
subshell_assignment=rejected outer=sonyliv
bash: line 1: declare: GRADED_DB: readonly variable
declare_global=rejected value=sonyliv
```

The actual scripts also refuse the ordinary old bypass before either failing stub is reached.

Exact command (stubs and `guard-test.invalid` make any unexpected fall-through non-networking):

```bash
bash -c '
curl() { printf "FAKE_CURL_REACHED\n" >&2; return 97; }
docker() { printf "FAKE_DOCKER_REACHED\n" >&2; return 98; }
export -f curl docker
env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE GRADED_DB=scratch TARGET=cloud CH_DATABASE=sonyliv CH_HOST=guard-test.invalid CH_PORT=8443 CH_USER=guard CH_PASSWORD=guard tools/build-model.sh 2>&1 | sed -n "1p"
printf "build_exit=%s\n" "${PIPESTATUS[0]}"
env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE GRADED_DB=scratch TARGET=cloud CH_DATABASE=sonyliv CH_HOST=guard-test.invalid CH_PORT=8443 CH_USER=guard CH_PASSWORD=guard tools/apply-sql.sh evidence/promotion/w1/codex-validation.md 2>&1 | sed -n "1p"
printf "apply_exit=%s\n" "${PIPESTATUS[0]}"
'
```

Exact output:

```text
tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.
build_exit=1
tools/apply-sql.sh: evidence/promotion/w1/codex-validation.md contains a destructive statement and 'sonyliv' is the GRADED database.
apply_exit=1
```

**Verdict: HOLDS for ordinary variable assignment.** A normal environment prefix, a child
subshell, and later `declare -g` do not change the subject.

### Executable invocation still permits an exported-function bypass

In Bash, an imported shell function named `readonly` shadows the special builtin. The caller can
therefore keep the exported `GRADED_DB=scratch` value while line 46/50 returns success.

Exact command:

```bash
bash -c '
readonly() { printf "SHADOWED_READONLY args=%s\n" "$*" >&2; return 0; }
curl() {
  local arg
  for arg in "$@"; do case "$arg" in *TRUNCATE*) printf "FAKE_CURL_REACHED sql=%s\n" "$arg" >&2 ;; esac; done
  return 97
}
docker() { printf "FAKE_DOCKER_REACHED\n" >&2; return 98; }
export -f readonly curl docker
env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE GRADED_DB=scratch TARGET=cloud CH_DATABASE=sonyliv CH_HOST=guard-test.invalid CH_PORT=8443 CH_USER=guard CH_PASSWORD=guard tools/build-model.sh
printf "shadowed_build_exit=%s\n" "$?"
' 2>&1 | rg 'SHADOWED_READONLY|FAKE_CURL_REACHED|shadowed_build_exit'
```

Exact output:

```text
SHADOWED_READONLY args=GRADED_DB=sonyliv
FAKE_CURL_REACHED sql=TRUNCATE TABLE session_intervals
shadowed_build_exit=97
```

Exact `apply-sql.sh` command:

```bash
bash -c '
readonly() { printf "SHADOWED_READONLY args=%s\n" "$*" >&2; return 0; }
docker() { printf "FAKE_DOCKER_REACHED\n" >&2; return 98; }
export -f readonly docker
env -u REBUILD_GRADED -u APPLY_GRADED_DESTRUCTIVE GRADED_DB=scratch TARGET=cloud CH_DATABASE=sonyliv CH_HOST=guard-test.invalid CH_PORT=8443 CH_USER=guard CH_PASSWORD=guard tools/apply-sql.sh evidence/promotion/w1/codex-validation.md
printf "shadowed_apply_exit=%s\n" "$?"
' 2>&1 | rg 'SHADOWED_READONLY|applying to CLOUD|FAKE_DOCKER_REACHED|shadowed_apply_exit'
```

Exact output:

```text
SHADOWED_READONLY args=GRADED_DB=sonyliv
applying to CLOUD: guard-test.invalid/sonyliv
  evidence/promotion/w1/codex-validation.md ... FAKE_DOCKER_REACHED
shadowed_apply_exit=1
```

The old bypass condition is restored: `CH_DATABASE=sonyliv` no longer equals the caller-preserved
`GRADED_DB=scratch`, so neither guard refuses. No authorization variable is involved.

### Conditional sourcing also bypasses both guards

Sourcing is per-shell as the brief warned. A pre-existing readonly caller value makes the assignment
fail. Because the source command is the condition of `if`, Bash suppresses `errexit` inside the
sourced file; execution continues with `GRADED_DB=scratch`.

Exact build command:

```bash
bash -c '
curl() {
  local arg
  for arg in "$@"; do
    case "$arg" in *TRUNCATE*) printf "FAKE_CURL_REACHED sql=%s\n" "$arg" >&2 ;; esac
  done
  return 97
}
docker() { return 98; }
export -f curl docker
export TARGET=cloud CH_DATABASE=sonyliv CH_HOST=guard-test.invalid CH_PORT=8443 CH_USER=guard CH_PASSWORD=guard
readonly GRADED_DB=scratch
if source tools/build-model.sh; then printf "sourced_build_status=accepted\n"; else printf "sourced_build_status=rejected\n"; fi
' tools/build-model.sh 2>&1 | rg 'readonly variable|FAKE_CURL_REACHED|sourced_build_status'
```

Exact output:

```text
tools/build-model.sh: line 46: GRADED_DB: readonly variable
FAKE_CURL_REACHED sql=TRUNCATE TABLE session_intervals
FAKE_CURL_REACHED sql=TRUNCATE TABLE cc_minute_delta
sourced_build_status=rejected
```

Exact apply command:

```bash
bash -c '
docker() { printf "FAKE_DOCKER_REACHED\n" >&2; return 98; }
export -f docker
export TARGET=cloud CH_DATABASE=sonyliv CH_HOST=guard-test.invalid CH_PORT=8443 CH_USER=guard CH_PASSWORD=guard
readonly GRADED_DB=scratch
if source tools/apply-sql.sh evidence/promotion/w1/codex-validation.md; then printf "sourced_apply_status=accepted\n"; else printf "sourced_apply_status=rejected\n"; fi
' tools/apply-sql.sh 2>&1 | rg 'readonly variable|applying to CLOUD|FAKE_DOCKER_REACHED|FAILED'
```

Exact output:

```text
tools/apply-sql.sh: line 50: GRADED_DB: readonly variable
applying to CLOUD: guard-test.invalid/sonyliv
  evidence/promotion/w1/codex-validation.md ... FAKE_DOCKER_REACHED
FAILED
```

**Verdict: DOES NOT HOLD.** `readonly` closes the ordinary prefix but does not make the fixed subject
independent of the caller. Both scripts can reach their destructive executor with neither intended
authorization flag.

## 5 · Other uncovered destructive routes

The code now honestly says `tools/ch`, `tools/load.sh`, and plain INSERT are outside these two narrow
guards. That is useful scoping, but the scanner's own intended scope is still incomplete: ordinary
destructive statements in a file pass its exact predicate.

Exact scanner command (function body is the predicate from `tools/apply-sql.sh:93-95`):

```bash
bash -c '
scan_probe() {
  local label="$1" sql="$2" scan
  scan="$(printf "%s" "$sql" | sed "s/'\''[^'\'']*'\''/'\'''\''/g" | sed "s/--.*//" | tr "\n" " ")"
  if printf "%s" "$scan" | grep -qiE "(^|[[:space:];])(DROP|TRUNCATE|DETACH|RENAME[[:space:]]+TABLE|EXCHANGE[[:space:]]+TABLES|REPLACE[[:space:]]+TABLE)[[:space:]]" \
     || printf "%s" "$scan" | grep -qiE "ALTER[[:space:]]+TABLE[^;]*(DELETE|UPDATE|DROP[[:space:]]+(COLUMN|PARTITION)|CLEAR[[:space:]]+COLUMN)"; then
    printf "%s=BLOCKED\n" "$label"
  else
    printf "%s=MISSED\n" "$label"
  fi
}
scan_probe lightweight_delete "DELETE FROM ev_raw WHERE user_id = '\''x'\'';"
scan_probe move_partition "ALTER TABLE ev_raw MOVE PARTITION tuple() TO TABLE ev_raw_sink;"
scan_probe replace_partition "ALTER TABLE ev_raw REPLACE PARTITION tuple() FROM ev_raw_source;"
scan_probe materialize_ttl "ALTER TABLE ev_raw MATERIALIZE TTL;"
scan_probe optimize_cleanup "OPTIMIZE TABLE ev_raw FINAL CLEANUP;"
scan_probe modify_column "ALTER TABLE ev_raw MODIFY COLUMN user_id String;"
'
```

Exact output:

```text
lightweight_delete=MISSED
move_partition=MISSED
replace_partition=MISSED
materialize_ttl=MISSED
optimize_cleanup=MISSED
modify_column=MISSED
```

These are valid statements on the local ClickHouse parser, not hypothetical token spellings.

Exact read-only parser command:

```bash
for statement in \
  "DELETE FROM ev_raw WHERE user_id = 'x'" \
  "ALTER TABLE ev_raw MOVE PARTITION tuple() TO TABLE ev_raw_sink" \
  "ALTER TABLE ev_raw REPLACE PARTITION tuple() FROM ev_raw_source" \
  "ALTER TABLE ev_raw MATERIALIZE TTL" \
  "OPTIMIZE TABLE ev_raw FINAL CLEANUP" \
  "ALTER TABLE ev_raw MODIFY COLUMN user_id String"; do
  printf 'SQL: %s\n' "$statement"
  docker exec ch clickhouse format --query "$statement"
done
```

Exact output:

```text
SQL: DELETE FROM ev_raw WHERE user_id = 'x'
DELETE FROM ev_raw WHERE user_id = 'x'
SQL: ALTER TABLE ev_raw MOVE PARTITION tuple() TO TABLE ev_raw_sink
ALTER TABLE ev_raw
    (MOVE PARTITION tuple() TO TABLE ev_raw_sink)
SQL: ALTER TABLE ev_raw REPLACE PARTITION tuple() FROM ev_raw_source
ALTER TABLE ev_raw
    (REPLACE PARTITION tuple() FROM ev_raw_source)
SQL: ALTER TABLE ev_raw MATERIALIZE TTL
ALTER TABLE ev_raw
    (MATERIALIZE TTL)
SQL: OPTIMIZE TABLE ev_raw FINAL CLEANUP
OPTIMIZE TABLE ev_raw FINAL CLEANUP
SQL: ALTER TABLE ev_raw MODIFY COLUMN user_id String
ALTER TABLE ev_raw
    (MODIFY COLUMN `user_id` String)
```

`DELETE FROM` deletes rows; `MOVE PARTITION` removes a partition from the source; `REPLACE PARTITION`
replaces target data; `MATERIALIZE TTL` can delete expired rows; `OPTIMIZE ... FINAL CLEANUP`
permanently cleans obsolete rows; and `MODIFY COLUMN` can rewrite/convert stored data. None requires
obfuscation or an unsupported comment/literal edge case.

**Verdict: DOES NOT HOLD.** There are additional simple destructive routes through the guarded
file-applier that the broadened grep does not cover.

## 6 · ADR 0018's scope correction

Exact command:

```bash
sed -n '18,25p;55,67p;148,156p' docs/adr/0018-one-target-one-database-no-cross-target-fallback.md
```

Exact output:

```text
> **Scope, narrowed 2026-08-02 after Codex check 5.** An earlier wording said this ADR "promotes a
> two-script fix to the rule every layer follows". **It does not, and the claim is withdrawn.** The
> rule is fully implemented on the two layers that carry the graded target — `tools/ch` and the Go
> binary — and only partially on the other shell tools, whose LOCAL paths still inherit the server's
> default database and whose `TARGET` is honoured but not validated. The measured per-layer status is
> the addendum at the end of this file. An accurate smaller claim beats an aspirational larger one:
> the failure this ADR exists to prevent is a *confident query against the wrong database*, and a doc
> that overstates its own coverage is that failure in prose.
2. **The database is always sent explicitly.** No query rides the server's default database.
   **Implemented on `tools/ch` and the Go binary, on BOTH targets, and on the CLOUD path of
   `apply-sql.sh` / `load.sh` / `reconcile.sh`.** Those three still send no database on their LOCAL
   path — measured, see the addendum. The graded database is Cloud-only, so no unqualified statement
   from these tools can reach it; the exposure is that a local check can silently answer from a
   different local database than the one under test.
3. **The environment beats `.env`** (capture before `set -a && . .env`, which otherwise overwrites).
   Implemented today in `internal/config` (the Go binary) and `tools/ch`. The other shell tools
   (`build-model.sh`, `apply-sql.sh`, `load.sh`, `reconcile.sh`, `truncation-test.sh`) still source
   `.env` without capturing first, so for them `.env` wins — exactly as
   [`RUNBOOK_UNSEEN.md`](../RUNBOOK_UNSEEN.md#a5--ch_database-in-the-environment-is-silently-ignored)
   §A5 warns. Extending the capture to those five scripts is open work in the same family as Q33;
   until then, the only way to point them at another database is to edit `.env`.
| Layer | Dies on an unrecognised `TARGET` | Sends an explicit database — CLOUD | Sends an explicit database — LOCAL | Environment beats `.env` |
|---|:--:|:--:|:--:|:--:|
| Go `internal/config` (`sonyliv …`) | ✅ | ✅ | ✅ | ✅ |
| `tools/ch` | ✅ | ✅ `$CH_DATABASE` | ✅ `$CH_DATABASE_LOCAL` | ✅ |
| `tools/build-model.sh` | ❌ | ✅ *(via `tools/ch`)* | ✅ *(via `tools/ch`)* | ❌ |
| `tools/reconcile.sh` | ❌ | ✅ `?database=` | ❌ server default | ❌ |
| `tools/apply-sql.sh` | ❌ | ✅ `--database` | ❌ server default | ❌ |
| `tools/load.sh` | ❌ | ✅ `?database=` | ❌ server default | ❌ |
| `tools/truncation-test.sh` | n/a — pins `DB=sonyliv_trunc` | ✅ `--database "$DB"` | ✅ | ❌ |
```

**Verdict: HOLDS.** The ADR did not silently keep the universal implementation claim. It explicitly
withdraws it, distinguishes rule from implementation, and names the remaining tools and behavior.
Narrowing is a legitimate answer to the prior finding.

## 7 · Check 4 — both read-only gates

Before execution, both files passed this write-token scan.

Exact command:

```bash
for gate in branch dev; do
  if [ "$gate" = branch ]; then source_cmd=(sed -n '1,$p' sql/90_reconcile.sql); else source_cmd=(git show origin/dev:sql/90_reconcile.sql); fi
  printf '%s: ' "$gate"
  if "${source_cmd[@]}" | sed 's/--.*//' | rg -ni '(^|[[:space:];])(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|OPTIMIZE|RENAME|REPLACE|DETACH|ATTACH|EXCHANGE)([[:space:];]|$)'; then
    printf 'WRITE_TOKEN_FOUND\n'
  else
    printf 'READ_ONLY_SCAN_CLEAR\n'
  fi
done
```

Exact output:

```text
branch: READ_ONLY_SCAN_CLEAR
dev: READ_ONLY_SCAN_CLEAR
```

### 4a · `origin/dev` deployed-spec gate

Exact command:

```bash
set -a
source /Users/barun/Developers/personal/clickathon-project/.env
set +a
dev_gate="$(git show origin/dev:sql/90_reconcile.sql | sed '$s/;$/ LIMIT 1000 SETTINGS max_execution_time=60, max_rows_to_read=1000000000, max_bytes_to_read=100000000000, max_result_rows=1000, timeout_before_checking_execution_speed=0 FORMAT PrettyCompact;/')"
tools/ch -c "$dev_gate"
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

**Verdict: HOLDS.** The graded database passes the deployed spec exactly: 17,028 / 0 / 0 / 2,917.

### 4b · this checked-out branch's own gate

Exact command:

```bash
branch_gate="$(sed '$s/;$/ LIMIT 1000 SETTINGS max_execution_time=60, max_rows_to_read=1000000000, max_bytes_to_read=100000000000, max_result_rows=1000, timeout_before_checking_execution_speed=0 FORMAT PrettyCompact;/' sql/90_reconcile.sql)"
tools/ch -c "$branch_gate"
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

The checked-out branch is W1 and does not carry ADR 0009's `>=` gate definition. Regardless of the
historical attribution, this brief explicitly changes the acceptance rule: “Any mismatch is a
failure, not skew.”

**Verdict: DOES NOT HOLD.** Check 4b fails under the requested rule.

## 8 · ADR 0011 survived

Exact commands:

```bash
tools/ch -c "SELECT name, origin FROM system.functions WHERE name IN ('lang_class','norm_app_version','norm_case','norm_lang','norm_version') ORDER BY name LIMIT 10 SETTINGS max_execution_time=30, max_rows_to_read=100000, max_result_rows=100, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
tools/ch -c "SELECT name, engine, metadata_modification_time FROM system.tables WHERE database = 'sonyliv' AND name IN ('v_cc_minute_delta_norm','v_concurrency_minute_audio_norm','v_dimension_drift','v_dimension_drift_summary') ORDER BY name LIMIT 10 SETTINGS max_execution_time=30, max_rows_to_read=100000, max_result_rows=100, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
tools/ch -c "SELECT norm_lang('HIN') AS hin_upper, norm_lang('hin-Hindi') AS hin_long, lang_class('HIN') AS hin_class, norm_app_version('5.0.36.00') AS app_version, norm_version('3.33.50_ADE') AS player_version, norm_case('Mweb') AS platform LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
tools/ch -c "WITH raw AS (SELECT minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta WHERE audio_language = 'hin' GROUP BY minute), normalised AS (SELECT minute, concurrent FROM v_concurrency_minute_audio_norm WHERE audio_language_norm = 'hin') SELECT (SELECT max(concurrent) FROM raw) AS raw_hin_peak, (SELECT max(concurrent) FROM normalised) AS normalised_hin_peak, normalised_hin_peak - raw_hin_peak AS delta, round(100 * delta / raw_hin_peak, 1) AS pct_increase LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000000, max_bytes_to_read=1000000000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
```

Exact output:

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
hin_upper	hin_long	hin_class	app_version	player_version	platform
hin	hin	named	5.0.36	3.33.50_ade	mweb
raw_hin_peak	normalised_hin_peak	delta	pct_increase
1774	2196	422	23.8
```

**Verdict: HOLDS.** All five functions and all four views are live on `sonyliv`; the behavior and
the 1,774 -> 2,196 Hindi pair reproduce.

## 9 · ADR 0014 survived

Exact commands:

```bash
tools/ch -c "WITH points AS (SELECT toStartOfHour(minute) AS hour, minute, toInt64(sum(sum(delta)) OVER (PARTITION BY toStartOfHour(minute) ORDER BY minute ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS concurrent FROM cc_minute_delta GROUP BY hour, minute), maxima AS (SELECT hour, max(concurrent) AS peak FROM points GROUP BY hour), independent AS (SELECT p.hour AS hour, min(m.peak) AS peak, minIf(p.minute, p.concurrent = m.peak) AS peak_minute, countIf(p.concurrent = m.peak) AS change_points_at_peak FROM points AS p INNER JOIN maxima AS m USING (hour) GROUP BY p.hour), stored AS (SELECT hour, peak, peak_minute FROM cc_hour_agg FINAL WHERE platform = '*' AND country = '*' AND content_id = -1 AND cube_level = 0) SELECT count() AS hours_compared, countIf(i.peak != s.peak) AS peak_mismatches, countIf(i.peak_minute != s.peak_minute) AS peak_minute_mismatches, countIf(i.change_points_at_peak >= 2) AS hours_with_tied_max_change_points FROM independent AS i INNER JOIN stored AS s USING (hour) LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000000, max_bytes_to_read=1000000000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
tools/ch -c "SELECT countIf(match(create_table_query, 'argMax\\s*\\(\\s*minute\\s*,\\s*[A-Za-z_]')) AS live_views_with_bare_argmax_minute, groupArrayIf(name, match(create_table_query, 'argMax\\s*\\(\\s*minute\\s*,\\s*[A-Za-z_]')) AS offending_views FROM system.tables WHERE database = 'sonyliv' AND engine = 'View' LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=100000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
```

Exact output:

```text
hours_compared	peak_mismatches	peak_minute_mismatches	hours_with_tied_max_change_points
98	0	0	51
live_views_with_bare_argmax_minute	offending_views
0	[]
```

**Verdict: HOLDS.** The independent earliest-minute derivation agrees for 98/98 live hours, and no
live view retains the bare `argMax(minute, ...)` form.

## 10 · Headline before and after

The before hours were re-derived read-only from `ev_raw` with this branch's pre-ADR-0009
`sql/30_build_intervals.sql`; no table was populated. The after hours are the live interval table.

Exact command:

```bash
before_model="$(sed '/^INSERT INTO session_intervals$/,/^WITH$/ { /^WITH$/!d; }' sql/30_build_intervals.sql)"
before_model="${before_model%;}"
tools/ch -c "SELECT count() AS interval_rows, round(sum(dateDiff('second', interval_start, interval_end)) / 3600, 1) AS counted_hours FROM ($before_model) LIMIT 1 SETTINGS max_execution_time=60, max_rows_to_read=1000000000, max_bytes_to_read=100000000000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
tools/ch -c "SELECT count() AS interval_rows, round(sum(dateDiff('second', interval_start, interval_end)) / 3600, 1) AS counted_hours FROM session_intervals FINAL LIMIT 1 SETTINGS max_execution_time=30, max_rows_to_read=1000000, max_bytes_to_read=1000000000, max_result_rows=10, timeout_before_checking_execution_speed=0 FORMAT TSVWithNames"
```

Exact output:

```text
interval_rows	counted_hours
30769	1949.3
interval_rows	counted_hours
30323	1978.1
```

The two gate summaries above independently supply the paired peaks: branch/pre-ADR-0009 truth
2,887; deployed/current truth 2,917.

**Verdict: HOLDS.** The full headline reproduces: **2,887 -> 2,917** and
**1,949.3 -> 1,978.1 hours**.

## 11 · Documentation currency

ADR 0018 itself is corrected, but other touched docs still overstate or contradict the branch.

Exact command:

```bash
sed -n '3,9p' docs/RUNBOOK_UNSEEN.md
sed -n '197,207p' sql/90_reconcile.sql
sed -n '3,10p' docs/GO.md
sed -n '61,67p' docs/adr/0018-one-target-one-database-no-cross-target-fallback.md
```

Exact output:

```text
> **Summary:** One command runs the whole path on a dataset we have never seen —
> `tools/unseen-run.sh <raw.csv> <content.csv>` — into the isolated database `sonyliv_unseen`,
> ending on the correctness gate. **Measured end to end: 47 s for 30,097 events, 58 s for 849,888
> events**; the path is fixed-cost dominated, so budget ~3 min even for a 5x-bigger day. **The
> committed gate `sql/90_reconcile.sql` does NOT work on a new day** — its five target minutes are
> 2026-07-26 literals, so it returns zero rows and `tools/reconcile.sh` reports PASS having compared
> nothing. That, plus nine more unseen-day assumptions (A1-A10) and five human decisions, is the body of
    -- Sample minutes DERIVED from the data: the peak, both boundaries, and two
    -- picked by a stable hash so the choice is reproducible but not cherry-picked.
    samples AS
    (
        SELECT arrayJoin([
            (SELECT argMax(minute, truth) FROM compared),
            (SELECT min(minute) FROM compared),
            (SELECT max(minute) FROM compared),
            (SELECT minute FROM compared ORDER BY cityHash64(minute, 17) LIMIT 1),
            (SELECT minute FROM compared ORDER BY cityHash64(minute, 99) LIMIT 1)
        ]) AS minute
> **Summary:** Go 1.26.4 pinned by [devbox.json](../devbox.json), entered automatically by
> [.envrc](../.envrc) via direnv, driven by the [Makefile](../Makefile). `make ci` runs exactly what
> GitHub Actions runs. Lint is golangci-lint **v2** (`.golangci.yml` is v2 schema — a v1 binary
> cannot read it). Layout is `cmd/` for binaries, `internal/` for everything else. Config comes from
> the SAME `.env` the bash tools in `tools/` read, so Go and shell can never disagree about which
> ClickHouse was loaded. Per ADR 0018 each target owns its variables — cloud reads
> `CH_HOST`+`CH_DATABASE`, local reads `CH_LOCAL_URL`+`CH_DATABASE_LOCAL`, both REQUIRED, no
> cross-target fallback. Every ClickHouse call takes a `context.Context` — enforced by the `noctx`
3. **The environment beats `.env`** (capture before `set -a && . .env`, which otherwise overwrites).
   Implemented today in `internal/config` (the Go binary) and `tools/ch`. The other shell tools
   (`build-model.sh`, `apply-sql.sh`, `load.sh`, `reconcile.sh`, `truncation-test.sh`) still source
   `.env` without capturing first, so for them `.env` wins — exactly as
   [`RUNBOOK_UNSEEN.md`](../RUNBOOK_UNSEEN.md#a5--ch_database-in-the-environment-is-silently-ignored)
   §A5 warns. Extending the capture to those five scripts is open work in the same family as Q33;
   until then, the only way to point them at another database is to edit `.env`.
```

The runbook describes a historical defect as current even though `sql/90_reconcile.sql` derives its
samples at lines 197-207. The Go summary says disagreement is impossible because the layers read the
same file, while ADR 0018 correctly documents different environment-precedence behavior that can
make them disagree. Both docs are in W1's diff from `origin/main`.

**Verdict: DOES NOT HOLD.** Check 6 fails.

## What could not be checked

- An authorized graded rebuild and an authorized destructive apply are **UNVERIFIABLE by design**:
  the brief forbids setting either authorization flag and forbids every corresponding Cloud write.
- The guard-bypass paths were taken only as far as failing in-process stubs. Whether a real
  ClickHouse account would authorize each mutation was deliberately not tested; the scripts had
  already selected `cloud/sonyliv` and handed the SQL to the executor.
- I did not rebuild the local `tie0014` scratch database. The required ADR 0014 claim was fully
  re-derived read-only against the live 98-hour tier, so a scratch write was unnecessary.

DO NOT PROMOTE — the graded-database guards remain caller-defeatable without either authorization flag, so destructive statements can reach the graded path.
