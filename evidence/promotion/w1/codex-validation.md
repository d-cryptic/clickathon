# W1 Foundations — Cross-Model Validation (Check 5)

> **Summary:** **DO NOT PROMOTE.** The four required `tools/ch` target probes all resolve correctly, and the
> correctness measurements hold: dev is `17,028 / 0 / 0 / 2,917`; this branch is `17,028 / 177 / 39 / 2,887`.
> Replacing only this branch's two strict pause-resume predicates (`>` → `>=`) removes all 177 mismatches,
> so the check-4 skew is completely attributable to dev commit `0c0f020`. The write-safety claim fails:
> caller-controlled `GRADED_DB` disables both guards, and the SQL grep misses executable destructive forms.
> ADR 0018's “every layer” claim also fails: several shell tools still use a server default and accept bad targets.

## Scope and safety

The requested branch was already checked out by the promotion worktree, so Git refused a second checkout:

```text
$ git checkout chore/promotion-w1-resume-the
fatal: 'chore/promotion-w1-resume-the' is already used by worktree at '/Users/barun/.superconductor/worktrees/clickathon-project/sc-paired-josephson-537f'
```

I checked out the fetched branch commit in detached mode, so the reviewed files are byte-identical without
touching the promotion agent's branch:

```text
$ git switch --detach origin/chore/promotion-w1-resume-the
HEAD is now at 64f2ed7 docs: W1 stops at check 4 again — the rebuild deployed a wave-2 spec the branch does not carry
$ git log --oneline -5
64f2ed7 docs: W1 stops at check 4 again — the rebuild deployed a wave-2 spec the branch does not carry
7551e1f docs: W1 promotion stops at check 4 — the graded database fails its own gate
2c4ff9f fix: guard the graded database against the exact mechanism that corrupted it
fb1f98a fix: one target resolves to one database on every layer (ADR 0018)
c729d9c docs: define the promotion gate and park what v1 will not do
```

This worktree had no `.env`. For live read-only checks I exported the existing main checkout's `.env` into
the process environment without copying or printing it. I never set `REBUILD_GRADED` or
`APPLY_GRADED_DESTRUCTIVE` on a write-script invocation, and never gave either variable an authorising value.
No Cloud write command was sent. The only created repository file is this report;
the temporary guard probe was removed after the refusal test.

## 1. Required target-resolution invocations

Credential preamble used for the four live probes:

```bash
set -a
. /Users/barun/Developers/personal/clickathon-project/.env
set +a
```

### `TARGET=cloud tools/ch`

```text
$ TARGET=cloud tools/ch "SELECT currentDatabase(), version()"
sonyliv	26.2.1.525
[exit 0]
```

**Verdict: HOLDS.** It reached database `sonyliv` on ClickHouse Cloud 26.2.1.525.

### `tools/ch -c`

```text
$ tools/ch -c "SELECT currentDatabase(), version()"
sonyliv	26.2.1.525
[exit 0]
```

**Verdict: HOLDS.** It reached database `sonyliv` on ClickHouse Cloud 26.2.1.525.

### Bare `tools/ch`

```text
$ tools/ch "SELECT currentDatabase(), version()"
default	26.7.1.1315
[exit 0]
```

**Verdict: HOLDS.** It reached local database `default` on ClickHouse 26.7.1.1315, not Cloud.

### Invalid target casing

```text
$ TARGET=Cloud tools/ch "SELECT currentDatabase(), version()"
tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.
[exit 1]
```

**Verdict: HOLDS.** It died before sending a query and did not fall through to local.

### Missing configuration

Before sourcing any external `.env`, the valid invocations all failed before making a request:

```text
$ TARGET=cloud tools/ch "SELECT currentDatabase(), version()"
tools/ch: no cloud database: set CH_DATABASE in .env (the graded database) or export it. Refusing to fall back to the server default — see ADR 0018.
[exit 1]
$ tools/ch "SELECT currentDatabase(), version()"
tools/ch: no local database: set CH_DATABASE_LOCAL in .env (the local data lives in 'default') or export it. CH_DATABASE deliberately does NOT apply here — it names the graded Cloud database. See ADR 0018.
[exit 1]
```

The Go configuration tests also pass:

```text
$ devbox run -- go test ./internal/config
Info: Running script "go" on /Users/barun/.superconductor/worktrees/clickathon-project/sc-resonant-yttrium-f7c3
Info: Ensuring packages are installed.
ok  	github.com/d-cryptic/clickathon/internal/config	0.525s
[exit 0]
```

**Verdict: HOLDS for `tools/ch` and Go.** It does not hold on every shell layer; see section 4.

## 2. Write guards

### `build-model.sh` refuses the ordinary graded rebuild

I explicitly unset all three guard-related variables before this test.

```text
$ TARGET=cloud tools/build-model.sh
tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.

  This truncates session_intervals and cc_minute_delta on the service we are
  scored on, then rebuilds them from ev_raw. If your working tree is on a
  stale base, the rebuild writes STALE SQL over correct answers and the
  result looks plausible. That has happened once.

  Before you override, confirm all three:
    1. git log --oneline -1        is a commit you meant to build from
    2. git status --porcelain      is clean
    3. you actually intend to replace the graded answers

  Then:  REBUILD_GRADED=yes TARGET=cloud tools/build-model.sh

  For any other purpose use a scratch database — sql/70_truncation_test.sql
  shows the pattern — or run without TARGET=cloud for local.
[exit 1]
```

**Verdict: HOLDS for the ordinary invocation.** The process exited before either `TRUNCATE` at
`tools/build-model.sh:70,75`.

### `apply-sql.sh` refuses an ordinary destructive file

Temporary probe (removed after the test):

```sql
-- DROP TABLE comment_only_should_be_ignored;
CREATE OR REPLACE VIEW harmless_guard_probe AS SELECT 1;
TRUNCATE TABLE must_be_blocked;
```

```text
$ sed 's/--.*//' evidence/promotion/w1/.fable-guard-test.sql | grep -niE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'
3:TRUNCATE TABLE must_be_blocked;
[exit 0]
$ TARGET=cloud tools/apply-sql.sh evidence/promotion/w1/.fable-guard-test.sql
tools/apply-sql.sh: evidence/promotion/w1/.fable-guard-test.sql contains DROP or TRUNCATE and 'sonyliv' is the GRADED database.

Applying it destroys answers we are scored on, and there is no undo. If that is
genuinely what you want, confirm the tree is the one you mean to apply
(git log --oneline -1 · git status --porcelain), then:

  APPLY_GRADED_DESTRUCTIVE=yes TARGET=cloud tools/apply-sql.sh evidence/promotion/w1/.fable-guard-test.sql

Otherwise point CH_DATABASE at a scratch database, or drop TARGET=cloud for
local. CREATE and CREATE OR REPLACE are NOT gated — this stops destructive
DDL only.
[exit 1]
```

**Verdict: HOLDS for the ordinary invocation.** It refused before invoking `docker`.

### Default `FILES` ordering

```text
$ nl -ba tools/apply-sql.sh | sed -n '25,31p;48,56p'
    25	# Files: whatever was passed, else every sql/*.sql in lexical order. 05_users.sh
    26	# is a shell script, not SQL, so the glob correctly skips it.
    27	if [ $# -gt 0 ]; then
    28	  FILES=("$@")
    29	else
    30	  FILES=(sql/*.sql)
    31	fi
    48	GRADED_DB="${GRADED_DB:-sonyliv}"
    49	if [ "$TARGET" = cloud ] && [ "${CH_DATABASE:-}" = "$GRADED_DB" ] \
    50	   && [ "${APPLY_GRADED_DESTRUCTIVE:-}" != yes ]; then
    51	  for f in "${FILES[@]}"; do
    52	    [ -f "$f" ] || continue
    53	    # Strip `--` comments first: ADR 0010's own commentary QUOTES a DROP, and a
    54	    # guard that greps comments as code blocks a clean run. The unseen-day
    55	    # rehearsal hit exactly that (finding R2).
    56	    if sed 's/--.*//' "$f" | grep -qiE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'; then
```

**Verdict: HOLDS.** `FILES=(sql/*.sql)` is assigned before the guard loop. I did not execute the bare
Cloud command because no current default SQL file contains a live `DROP`/`TRUNCATE`; it would proceed to
`CREATE`/`INSERT`, violating the read-only requirement. A comment-stripped scan returned no default file.

### Simple `--` comments and allowed `CREATE`

```text
$ printf '%s\n' '-- DROP TABLE comment_only;' 'CREATE OR REPLACE VIEW v AS SELECT 1;' 'TRUNCATE TABLE live;' | sed 's/--.*//' | grep -niE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'
3:TRUNCATE TABLE live;
[exit 0]
$ printf '%s\n' 'CREATE TABLE t (x UInt8);' 'CREATE OR REPLACE VIEW v AS SELECT 1;' | sed 's/--.*//' | grep -niE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'
[exit 1: no destructive match]
```

**Verdict: HOLDS for simple line comments and `CREATE`.** The comment is removed, the live `TRUNCATE`
is detected, and `CREATE`/`CREATE OR REPLACE` do not match.

### Authorisation propagation

```text
$ rg -n 'APPLY_GRADED_DESTRUCTIVE=' tools/build-model.sh
71:TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/30_build_intervals.sql >/dev/null
76:TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/40_deltas.sql >/dev/null
80:TARGET="$TARGET" APPLY_GRADED_DESTRUCTIVE="${REBUILD_GRADED:-}" tools/apply-sql.sh sql/20_views.sql >/dev/null
```

**Verdict: HOLDS by inspection.** `REBUILD_GRADED=yes` would propagate `yes` to every nested
`apply-sql.sh` call. Runtime execution against `sonyliv` is **UNVERIFIABLE by design** because the brief
forbids setting either override against the real service.

### Finding W1-1 — caller-controlled `GRADED_DB` disables both guards

Both scripts use `GRADED_DB="${GRADED_DB:-sonyliv}"`. The safe evaluation below reproduces their exact
conditions without invoking either write script:

```text
$ env -u APPLY_GRADED_DESTRUCTIVE TARGET=cloud CH_DATABASE=sonyliv GRADED_DB=scratch bash -c 'if [ "$TARGET" = cloud ] && [ "${CH_DATABASE:-}" = "${GRADED_DB:-sonyliv}" ] && [ "${APPLY_GRADED_DESTRUCTIVE:-}" != yes ]; then echo guard=ACTIVE; else echo guard=SKIPPED; fi'
guard=SKIPPED
$ env -u REBUILD_GRADED TARGET=cloud CH_DATABASE=sonyliv GRADED_DB=scratch bash -c 'TARGET_DB="${CH_DATABASE:-}"; if [ "$TARGET" = cloud ] && [ "$TARGET_DB" = "${GRADED_DB:-sonyliv}" ] && [ "${REBUILD_GRADED:-}" != yes ]; then echo build_guard=ACTIVE; else echo build_guard=SKIPPED; fi'
build_guard=SKIPPED
$ rg -n 'GRADED_DB=' tools/apply-sql.sh tools/build-model.sh
tools/apply-sql.sh:48:GRADED_DB="${GRADED_DB:-sonyliv}"
tools/build-model.sh:37:GRADED_DB="${GRADED_DB:-sonyliv}"
```

With `GRADED_DB=scratch`, `CH_DATABASE=sonyliv` no longer equals `GRADED_DB`, so `build-model.sh`
continues directly to its two unqualified `TRUNCATE`s and `apply-sql.sh` skips its scan. Neither intended
override is required.

**Verdict: DOES NOT HOLD.** The graded database identity must not be caller-redefinable in the condition
whose only purpose is to protect that fixed database.

### Finding W1-2 — the destructive-SQL detector is bypassable

The grep is line-oriented and the `sed` is not SQL-string-aware:

```text
$ printf '%s\n' 'TRUNCATE' 'TABLE session_intervals;' | sed 's/--.*//' | grep -niE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'
[exit 1: guard misses newline-separated keyword]
$ printf '%s\n' "SELECT '-- not a comment'; TRUNCATE TABLE session_intervals;" | sed 's/--.*//' | grep -niE '(^|[[:space:];])(DROP|TRUNCATE)[[:space:]]'
[exit 1: guard mistakes string content for a comment]
```

Both inputs are executable SQL spellings (the second is multi-statement), but both pass the predicate. The same line-boundary
defect applies to `DROP\nTABLE`; block comments between tokens are another unhandled spelling.

I then verified both spellings against the local ClickHouse parser. The probe table was checked absent before
and after; `IF EXISTS` ensured no object or data changed:

```text
$ tools/ch "SELECT count() FROM system.tables WHERE database=currentDatabase() AND name='fable_guard_probe_never_create_9f7c'"
0
$ printf 'TRUNCATE\nTABLE IF EXISTS fable_guard_probe_never_create_9f7c;\n' | docker exec -i ch clickhouse-client --database default --multiquery
[exit 0]
$ printf "SELECT '-- not a comment'; TRUNCATE TABLE IF EXISTS fable_guard_probe_never_create_9f7c;\n" | docker exec -i ch clickhouse-client --database default --multiquery
-- not a comment
[exit 0]
$ tools/ch "SELECT count() FROM system.tables WHERE database=currentDatabase() AND name='fable_guard_probe_never_create_9f7c'"
0
```

**Verdict: DOES NOT HOLD.** Stripping ordinary `--` comments is present, but the scanner is not a reliable
destructive-statement guard.

### Finding W1-3 — other destructive paths are outside both guards

```text
$ rg -n 'Q=|data-binary.*\$Q|q "TRUNCATE|INSERT INTO' tools/ch tools/build-model.sh tools/load.sh
tools/build-model.sh:70:q "TRUNCATE TABLE session_intervals" >/dev/null
tools/build-model.sh:75:q "TRUNCATE TABLE cc_minute_delta" >/dev/null
tools/ch:46:Q="${1:?usage: tools/ch [-c] \"SQL\"   (or TARGET=cloud tools/ch \"SQL\")}"
tools/ch:52:    --user "${CH_USER}:${CH_PASSWORD}" --data-binary "$Q"
tools/ch:57:    --data-binary "$Q"
tools/load.sh:45:run "INSERT INTO content_dim SELECT content_id, title, video_type, category FROM input('$CONTENT_COLS') FORMAT CSVWithNames" < "$CONTENT"
tools/load.sh:48:run "INSERT INTO ev_raw SELECT content_id, video_session_id, user_id, event_type, event, toDateTime64(event_timestamp/1000, 3), platform, app_version, country, audio_language, subtitle_language, player_version, toDateTime64(session_start_epoch/1000, 3) FROM input('$RAW_COLS') FORMAT CSVWithNames" < "$RAW"
```

`tools/ch` forwards arbitrary SQL to Cloud without a graded-write check. `apply-sql.sh` also intentionally ignores
destructive operations expressed as `ALTER ... DELETE`, `DELETE`, `RENAME`, or overwriting `INSERT`s. I did not
exercise any of these routes against Cloud.

**Verdict: DOES NOT HOLD as a general graded-database safety boundary.** The two narrow script claims are not a
complete write guard, and the brief explicitly asked whether another destructive route exists.

## 3. Correctness gate and spec-skew attribution

Before running either gate query I scanned both SQL versions for `INSERT`, `UPDATE`, `DELETE`, `ALTER`, `CREATE`,
`DROP`, `TRUNCATE`, `OPTIMIZE`, `RENAME`, and `REPLACE`; the scan produced no output and exited 1 (no matches).
The gate commands below ran after the credential preamble in section 1 and this host-only normalization:

```bash
cloud_host="${CH_HOST#https://}"
cloud_host="${cloud_host#http://}"
cloud_host="${cloud_host%/}"
```

### 4a — dev gate against the graded database

Exact read-only command (credentials remained environment variables):

```bash
git show origin/dev:sql/90_reconcile.sql |
  curl -sS --fail-with-body \
    "https://${cloud_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
```

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

**Verdict: HOLDS.** Dev's deployed-spec gate reports 17,028 minutes, 0 mismatched, max absolute difference 0,
and peak 2,917.

### 4b — this branch's gate

```bash
curl -sS --fail-with-body \
  "https://${cloud_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
  --user "${CH_USER}:${CH_PASSWORD}" --data-binary @sql/90_reconcile.sql
```

The exact SUMMARY and the reported mismatch samples were:

```text
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
```

**Verdict: HOLDS as the claimed expected skew.** The result is exactly 177 mismatches with maximum absolute
difference 39. The old-spec truth peak is 2,887; the served post-fix peak is 2,917.

### Attribution to `0c0f020` and only the pause-resume predicate

Only one dev commit touches the gate after this branch:

```text
$ git log --oneline --reverse HEAD..origin/dev -- sql/90_reconcile.sql
0c0f020 fix: close a paused window on a same-second resume, in the model and the gate
```

Its executable gate change is in the pause-window `p2.rs` lookup: two strict predicates become inclusive,
plus an outer filter that removes zero-length pause windows.

```text
$ printf 'branch strict pause-resume predicates: '; rg -o "x -> x > p, p2.rs" sql/90_reconcile.sql | wc -l | tr -d ' '
branch strict pause-resume predicates: 2
$ printf 'branch inclusive pause-resume predicates: '; rg -o "x -> x >= p, p2.rs" sql/90_reconcile.sql | wc -l | tr -d ' '
branch inclusive pause-resume predicates: 0
$ printf 'dev strict pause-resume predicates: '; git show origin/dev:sql/90_reconcile.sql | rg -o "x -> x > p, p2.rs" | wc -l | tr -d ' '
dev strict pause-resume predicates: 0
$ printf 'dev inclusive pause-resume predicates: '; git show origin/dev:sql/90_reconcile.sql | rg -o "x -> x >= p, p2.rs" | wc -l | tr -d ' '
dev inclusive pause-resume predicates: 2
```

The stronger isolation test changes only those two predicates in this branch. It deliberately does **not** add
dev's zero-length-window filter:

```bash
sed 's/x -> x > p, p2.rs/x -> x >= p, p2.rs/g' sql/90_reconcile.sql |
  curl -sS --fail-with-body \
    "https://${cloud_host}:${CH_PORT}/?database=${CH_DATABASE}&default_format=PrettyCompact" \
    --user "${CH_USER}:${CH_PASSWORD}" --data-binary @-
```

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

This output is identical to dev's complete gate output. Because the exhaustive SUMMARY moves from 177 to 0
when only the two `p2.rs` operators change, every mismatching minute is explained by that operator. Because the
no-filter variant already matches every served minute, dev's outer zero-length filter has no effect at minute
grain. The strict lookup into `run_ts` remains unchanged, as required for the permissive branch.

**Verdict: HOLDS.** All 177 are real `>`/`>=` pause-window spec skew from `0c0f020`; no unexplained residual
mismatch remains.

### Checked-in `evidence/reconcile.txt` and parser

I re-ran the underlying branch gate read-only and compared its SUMMARY fields with the checked-in file:

```text
live SUMMARY:  1. │   0 │ SUMMARY  │ minutes_compared=17028 │ mismatched=177 │ max_abs_diff=39 │ peak=2887 │ MISMATCH │
file SUMMARY:  1. │   0 │ SUMMARY  │ minutes_compared=17028 │ mismatched=177 │ max_abs_diff=39 │ peak=2887 │ MISMATCH │
live fields: minutes_compared=17028 mismatched=177 max_abs_diff=39 peak=2887
file fields: minutes_compared=17028 mismatched=177 max_abs_diff=39 peak=2887
parser COMPARED=17028
parser verdict=FAILED (MISMATCH token present)
```

**Verdict: HOLDS.** The evidence SUMMARY agrees exactly with the fresh query. The script parser finds the
`MISMATCH` token first and fails; it does not misread this result as a pass.

## 4. ADR 0018 and documentation

### Finding W1-4 — “one target, one database on every layer” is not implemented

ADR 0018 says:

```text
$ rg -n 'Resolution rule, every layer|database is always sent explicitly|unrecognised value dies|A fresh clone without|naming the variable — on every layer' docs/adr/0018-one-target-one-database-no-cross-target-fallback.md
37:**Resolution rule, every layer:**
46:2. **The database is always sent explicitly.** No query rides the server's default database.
54:4. **`TARGET` is read from the environment on every layer, and an unrecognised value dies.**
106:- A fresh clone without `.env`, or an `.env` missing a database variable, fails with a message
107:  naming the variable — on every layer.
```

But `apply-sql.sh`'s local path supplies no database, and its two-way `if` treats every non-`cloud` target as
local. These no-write probes stop at a missing input file after target selection:

```text
$ env -u CH_DATABASE_LOCAL TARGET=local tools/apply-sql.sh /definitely/not/a/file.sql
applying to LOCAL: docker exec ch
no such file: /definitely/not/a/file.sql
[exit 1]
$ TARGET=Cloud tools/apply-sql.sh /definitely/not/a/file.sql
applying to LOCAL: docker exec ch
no such file: /definitely/not/a/file.sql
[exit 1]
```

It neither requires `CH_DATABASE_LOCAL` nor rejects `TARGET=Cloud`; it selects local and would run:

```text
tools/apply-sql.sh:81:    docker exec -i ch clickhouse-client --multiquery < "$f"
```

`load.sh` and the local multi-line path in `reconcile.sh` have the same default-database behavior:

```text
tools/load.sh:33:    docker exec -i ch clickhouse-client --query "$1"
tools/reconcile.sh:30:    docker exec -i ch clickhouse-client --format PrettyCompact < "$1"
```

All three use `if [ "$TARGET" = cloud ]; then ... else ...`, so an unrecognised target falls to local. None
sends `CH_DATABASE_LOCAL`; all inherit the local user's server default. `build-model.sh` calls these paths and
also accepts every non-`cloud` value as local.

**Verdict: DOES NOT HOLD.** The required four `tools/ch` spellings work, but ADR 0018's promoted “every layer”
invariant is false.

### ADR 0018 contradicts itself and the code

The ADR accurately admits at lines 48–53 that only Go and `tools/ch` implement environment precedence, while
five other scripts still let `.env` win. That directly narrows the summary's “environment beats `.env`” claim.
More seriously, its “known residue” is factually wrong for this branch:

```text
$ rg -n 'Known residue|fall back to .*CH_DATABASE' docs/adr/0018-one-target-one-database-no-cross-target-fallback.md
96:**Known residue (owned elsewhere, flagged not fixed):** the local chains in `tools/apply-sql.sh` and
97:`tools/load.sh` still fall back to `CH_DATABASE` after `CH_DATABASE_LOCAL`. Dead in practice now
```

There is no `CH_DATABASE_LOCAL` reference in either script. They do not have the described fallback chain;
they omit the local database argument entirely. The consequence at lines 103–107 that the bug-11 scripts
resolve identically and missing variables fail “on every layer” is also false.

**Verdict: DOES NOT HOLD.** ADR 0018 does not describe the promoted branch's current code.

### `docs/GO.md`

The Go-specific claim is correct and the tests pass. Its seven-line summary overclaims beyond Go:

```text
$ rg -n 'SAME .*env|Go and shell|CH_HOST.*CH_DATABASE|cross-target fallback' docs/GO.md
7:> the SAME `.env` the bash tools in `tools/` read, so Go and shell can never disagree about which
9:> `CH_HOST`+`CH_DATABASE`, local reads `CH_LOCAL_URL`+`CH_DATABASE_LOCAL`, both REQUIRED, no
10:> cross-target fallback. Every ClickHouse call takes a `context.Context` — enforced by the `noctx`
```

`apply-sql.sh`, `load.sh`, and `reconcile.sh` prove that shell tools can still disagree and that the local
database variable is not required on every layer.

**Verdict: DOES NOT HOLD as written.** The detailed Go `config.Load` paragraph is accurate; the summary's
Go-versus-shell guarantee is not.

### `.env.example`

```text
$ rg -n 'REQUIRED \(ADR 0018\)|never read by the local target|apply-sql.sh/load.sh prefer|CH_DATABASE when both|CH_DATABASE_LOCAL=default' .env.example
14:# REQUIRED (ADR 0018): the database local work targets. The local container's
16:# is never read by the local target: Go and tools/ch fail loudly if this is
17:# unset rather than borrowing it, and apply-sql.sh/load.sh prefer it over
18:# CH_DATABASE when both are set.
19:CH_DATABASE_LOCAL=default
```

The Go/`tools/ch` sentence is correct. The `apply-sql.sh`/`load.sh` sentence is false: neither file mentions
`CH_DATABASE_LOCAL`, so neither can prefer it.

**Verdict: DOES NOT HOLD.** The example defines the right variable but misstates which tools consume it.

## 5. What I could not check

- An authorised graded rebuild and authorised destructive apply are **UNVERIFIABLE** under this brief because
  exercising them requires the explicitly prohibited overrides. Propagation was verified statically only.
- The `GRADED_DB` and SQL-scanner bypasses were not executed against Cloud; doing so would issue exactly the
  forbidden writes. Their branch conditions/predicates were evaluated without calling the write scripts.
- Bare `TARGET=cloud tools/apply-sql.sh` was not run: the current default glob contains no live
  `DROP`/`TRUNCATE`, so it would pass the guard and perform other Cloud writes. Placement after the default was
  verified directly from the executed source.
- I did not run `tools/reconcile.sh` itself because it overwrites tracked `evidence/reconcile.txt`, outside my
  ownership. I ran its read-only `sql/90_reconcile.sql` query directly, then exercised the exact parser checks
  against the existing evidence file.

DO NOT PROMOTE — `GRADED_DB` is caller-overridable, so both graded-database guards can be disabled without either intended authorisation flag.
