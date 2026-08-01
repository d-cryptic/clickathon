# W1 — answering Codex check 5, with the measurement for each finding

> **Summary:** Codex returned **DO NOT PROMOTE** on the W1 foundations branch and was right twice.
> `GRADED_DB` was caller-overridable — closed with `readonly`, and **proven** by running the *pre-fix*
> script with unroutable credentials: it walked past the guard to its first `TRUNCATE` while the fixed
> script refuses. The destructive-form scanner now blocks **14 of 14** probe spellings, including the
> two line-oriented bypasses `06a720d` alone did not close, with **0 false positives** across
> `sql/*.sql`. ADR 0018's *"every layer"* claim is **withdrawn** and replaced with a measured
> nine-layer table. Gates re-run read-only: **4a PASS**; **4b 177 · 39 · peak 2,887**, the known spec
> skew, re-attributed to `0c0f020` by isolation — two characters take it to 0. `make ci` green.

Answered 2026-08-02 from worktree `sc-coupled-squid-f88a`, branch
`chore/promotion-w1-foundations`. The verdict answered is
[`codex-validation.md`](codex-validation.md), copied onto this branch so the finding and its answer
sit together.

**Nothing here was tested by overriding a guard.** `REBUILD_GRADED` and `APPLY_GRADED_DESTRUCTIVE`
were never set, to any value. A guard is tested by making it **refuse** — which needs no override —
and by making the *unfixed* version fail somewhere harmless. That is the method throughout.

---

## Finding W1-1 (BLOCKING) · caller-controlled `GRADED_DB` disabled both guards

**Codex:** both scripts used `GRADED_DB="${GRADED_DB:-sonyliv}"`, so
`CH_DATABASE=sonyliv GRADED_DB=scratch` no longer matches and the guard is skipped —
`build-model.sh` continues to its two unqualified `TRUNCATE`s and `apply-sql.sh` skips its scan.
Neither intended override is required.

**Answer: fixed**, by cherry-picking `06a720d`'s substance into both files (the diff is adapted, not
applied verbatim: this branch's `apply-sql.sh` guards on
`[ "$TARGET" = cloud ] && [ "$CH_DATABASE" = "$GRADED_DB" ]` where `dev`'s guards on `$DB`, so the
context hunks differ).

```bash
$ grep -n 'GRADED_DB' tools/build-model.sh tools/apply-sql.sh | grep -v '^\s*#'
tools/build-model.sh:  readonly GRADED_DB=sonyliv
tools/apply-sql.sh:    readonly GRADED_DB=sonyliv
```

### How it was proven without ever risking the graded database

The whole difficulty is that a *failed* guard means a `TRUNCATE` against `sonyliv`. So the test was
run with **deliberately unroutable credentials** — `CH_HOST=guard-test.invalid` — and this worktree
has no `.env`, so those are genuinely the values the scripts see. A guard that failed to refuse would
therefore die at the socket, not at the graded service. That makes the *pre-fix* script safe to run,
which is what turns this from an assertion into a measurement.

```text
FIXED script
  A · TARGET=cloud tools/build-model.sh
      exit=1 | tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.
  B · GRADED_DB=scratch TARGET=cloud tools/build-model.sh          ← the Codex bypass
      exit=1 | tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.

PRE-FIX script (cd0010b:tools/build-model.sh), same two invocations
  A' · TARGET=cloud …
      exit=1 | tools/build-model.sh: REFUSING to rebuild the graded database 'sonyliv'.
  B' · GRADED_DB=scratch TARGET=cloud …
      exit=6 | == target: cloud            ← WALKED PAST THE GUARD
```

Exit **6** is curl's "couldn't resolve host": the pre-fix script had already passed the refusal
block, printed its banner and reached `q "TRUNCATE TABLE session_intervals"`. With a real `.env` in
the directory that statement would have executed. That is the finding, reproduced end to end, with
the damage routed into a DNS error. The temporary copy of the old script was removed immediately
after the run.

---

## Finding W1-2 · the destructive-SQL detector was bypassable

**Codex:** the scanner is line-oriented and its `sed` is not string-aware, so two executable
spellings pass — `TRUNCATE\nTABLE session_intervals;` (keyword split across lines) and
`SELECT '-- not a comment'; TRUNCATE TABLE session_intervals;` (the `--` inside a string literal
makes `sed 's/--.*//'` delete the live statement). Both were verified against the ClickHouse parser.

**Answer: fixed, and `06a720d` alone would NOT have fixed it.** That commit broadened the *form
list*; it left the line-orientation and the comment-stripping order untouched. Measured, before this
branch's change:

```text
split_keyword    STILL PASSES THE SCANNER
fake_comment     STILL PASSES THE SCANNER
block_comment    BLOCKED
```

So the scan is now three normalising steps, in an order that is itself the fix:

1. **Blank single-quoted string literals** (`s/'[^']*'/''/g`) — *before* anything looks for a
   comment, so a `--` inside a literal can no longer swallow the statement after it.
2. **Strip `--` comments**, per line — ADR 0010's own commentary quotes a `DROP`, and the unseen-day
   rehearsal (finding R2) already showed that greping comments as code blocks a clean run.
3. **Join lines** — so `TRUNCATE\nTABLE` is visible. Only *after* step 2, so joining can never
   resurrect a commented-out statement.

### The full probe matrix, every run with `GRADED_DB=scratch`

| probe | before `06a720d` | after `06a720d` | after this branch |
|---|:--:|:--:|:--:|
| `TRUNCATE TABLE …` | blocked | blocked | **BLOCKED** |
| `DROP TABLE …` | blocked | blocked | **BLOCKED** |
| `ALTER TABLE … DELETE WHERE` | MISSED | blocked | **BLOCKED** |
| `ALTER TABLE … UPDATE` | MISSED | blocked | **BLOCKED** |
| `ALTER TABLE … DROP COLUMN` | MISSED | blocked | **BLOCKED** |
| `ALTER TABLE … DROP PARTITION` | MISSED | blocked | **BLOCKED** |
| `ALTER TABLE … CLEAR COLUMN` | MISSED | blocked | **BLOCKED** |
| `DETACH TABLE …` | MISSED | blocked | **BLOCKED** |
| `RENAME TABLE …` | MISSED | blocked | **BLOCKED** |
| `EXCHANGE TABLES …` | MISSED | blocked | **BLOCKED** |
| `REPLACE TABLE …` | MISSED | blocked | **BLOCKED** |
| `TRUNCATE\nTABLE …` (split keyword) | MISSED | **MISSED** | **BLOCKED** |
| `SELECT '-- …'; TRUNCATE …` (literal) | MISSED | **MISSED** | **BLOCKED** |
| `/* block */ TRUNCATE …` | blocked | blocked | **BLOCKED** |
| `-- DROP TABLE …` (comment only) | passes ✔ | passes ✔ | **passes ✔** |
| `CREATE OR REPLACE VIEW …` | passes ✔ | passes ✔ | **passes ✔** |

The last two *must* pass — `CREATE` and `CREATE OR REPLACE` are how views and UDFs are legitimately
applied to `sonyliv`, and gating them turns the guard into ceremony people route around. They exit 1
only because they proceed to the apply step and die at `guard-test.invalid`
(`DB::NetException: Not found address of host`), which is itself the proof that they were not gated.

### False positives, checked rather than hoped

Every default `sql/*.sql` was run through the exact new predicate:

```text
$ for f in sql/*.sql; do <the scan> && echo "WOULD BLOCK: $f"; done
  [nothing listed — no default sql/ file trips the broadened scanner]
```

### What is still not handled, stated rather than implied

It is a **scanner, not a parser**, and the file now says so: `'` escaping inside a literal, and a
`/* */` block comment spanning a keyword, are not handled. Anyone who needs a guarantee needs a
parser; what this gives is a high floor against the spellings that actually occur.

---

## Finding W1-3 · these guards are not a complete write boundary

**Codex:** `tools/ch` forwards arbitrary SQL to Cloud with no graded-write check; `tools/load.sh`
`INSERT`s into `content_dim` and `ev_raw`; `apply-sql.sh` ignores `ALTER … DELETE`, `DELETE`,
`RENAME` and overwriting `INSERT`s by design. So the two narrow script claims are not a complete
write guard.

**Answer: accepted, and the claim is narrowed in the code itself** — a boundary note above the guard
in `tools/apply-sql.sh` stating exactly what it is (a refusal to apply a *file* containing
destructive DDL through *this script*) and exactly what it is not (a write boundary around
`sonyliv`), naming the three routes that bypass it.

This is the honest fix rather than the ambitious one. A guard sold as more than it is gets trusted
for more than it can do — and that is not hypothetical here: `evidence/promotion/w1/04f` already
records that **neither of these guards would have caught the 2026-08-01 corruption**, because the
door it came through was `tools/publish-test.sh`'s unqualified `INSERT`s. What would have caught it
is ADR 0018's resolution rule applied to that script, which is queue item **Q33** and belongs to the
wave that carries the file.

---

## Finding W1-4 · ADR 0018's *"every layer"* claim overstates

**Codex:** several shell tools still fall back to a server default and accept bad targets, so the
claim does not hold.

**Answer: the claim is WITHDRAWN**, not softened. `docs/adr/0018` now opens with an explicit scope
note — "an earlier wording said this ADR promotes a two-script fix to the rule every layer follows.
It does not, and the claim is withdrawn" — rules 2, 4 and 5 are narrowed to the layers that implement
them, and a dated addendum carries the measured table. **Narrowing was chosen over fixing five
scripts**: this promotion's scope is the two layers that touch the graded target, and widening it
would mean promoting five untested script changes on the strength of a sentence in an ADR — the exact
move check 1 exists to prevent. The open work is named, with the idiom to apply.

| Layer | Dies on unrecognised `TARGET` | Explicit DB — CLOUD | Explicit DB — LOCAL | Env beats `.env` |
|---|:--:|:--:|:--:|:--:|
| Go `internal/config` | ✅ | ✅ | ✅ | ✅ |
| `tools/ch` | ✅ | ✅ | ✅ | ✅ |
| `tools/build-model.sh` | ❌ | ✅ via `tools/ch` | ✅ via `tools/ch` | ❌ |
| `tools/reconcile.sh` | ❌ | ✅ | ❌ | ❌ |
| `tools/apply-sql.sh` | ❌ | ✅ | ❌ | ❌ |
| `tools/load.sh` | ❌ | ✅ | ❌ | ❌ |
| `tools/truncation-test.sh` | n/a (pins `DB`) | ✅ | ✅ | ❌ |
| `tools/unseen-run.sh` | n/a (pins `DB`) | ✅ | n/a | works around it with a sandboxed `.env` |
| `tools/stats` | n/a (local only) | n/a | ❌ | ❌ |

### The two ❌ columns, measured

```text
$ TARGET=Cloud tools/ch "SELECT 1"
tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.

$ TARGET=Cloud tools/apply-sql.sh <SELECT currentDatabase() probe>
applying to LOCAL: docker exec ch          ← a value that is neither 'local' nor 'cloud', accepted
  …probe.sql ... default	26.7.1.1315
```

Distinguishing "sent the right database" from "sent nothing and got lucky" needs a database that is
**not** the server default. Point `CH_DATABASE_LOCAL` at one and ask each layer what it reached:

```text
$ CH_DATABASE_LOCAL=w2ans tools/ch "SELECT currentDatabase()"
w2ans                                      ← explicit
$ CH_DATABASE_LOCAL=w2ans sonyliv verify -target local
… database w2ans (user app)                ← explicit
$ CH_DATABASE_LOCAL=w2ans TARGET=local tools/apply-sql.sh <probe>
  …probe.sql ... default                   ← IGNORED, server default answered
$ docker exec -i ch clickhouse-client --query "SELECT currentDatabase()"    # load.sh's exact idiom
default
$ docker exec -i ch clickhouse-client --format TSV < probe.sql              # reconcile.sh's exact idiom
default	26.7.1.1315
```

**Not at risk: the graded database.** It exists only on Cloud, and every cloud path above sends its
database explicitly, so no unqualified statement from these tools can reach `sonyliv`. **At risk: the
meaning of a local check** — a local reconcile or apply can silently answer from whichever database
the `app` user defaults to rather than the one under test. It is a correctness-of-evidence problem,
not a data-loss problem, and the ADR now says which one it is.

---

## The ADR-vs-tree grep, run rather than assumed

The rule the two verdicts created: *a cherry-picked feature is not the ADR that introduced it — grep
the promoted tree for what the ADR says is gone.* ADR 0018 is the only ADR on this branch. What it
says is gone, and whether it is:

| ADR 0018 says | verified |
|---|---|
| `tools/ch` "sent no database at all locally and inherited the server default" — fixed | ✅ `CH_DATABASE_LOCAL=w2ans tools/ch …` → `w2ans`, not `default` |
| Go "read `CH_DATABASE` even for local work" — fixed | ✅ `sonyliv verify -target local` → `database w2ans`; pinned by `TestLoadLocalNeverReadsCloudDatabase` |
| `TARGET=cloud tools/ch` "silently queried local" — fixed | ✅ `TARGET=Cloud` dies before any request; `TARGET=cloud` reaches `sonyliv` |
| local schema drift: "4 drifted columns, all rebuilt; **0 remain**" | ✅ re-measured today — **0 type differences** on every column shared between local `default` and cloud `sonyliv` across `ev_raw`, `session_intervals`, `cc_minute_delta`, `cc_minute_stateless`, `content_dim` |
| — | ⚠️ two **cloud-only columns** exist that the ADR's "intentional differences" table does not name: `ev_raw.ingested_at` and `session_intervals.build_version`. That table says local carries a subset of *objects*; these are columns on tables local does have. Additive, later-ADR schema not yet applied to the local container — not drift in the sense this ADR repaired, but recorded rather than glossed |

## One doc defect found here and deliberately left to W2

`docs/RUNBOOK_UNSEEN.md` is in this branch's diff (for the §A5 environment-vs-`.env` narrowing), and
its first seven lines still say the committed gate "does NOT work on a new day — its five target
minutes are 2026-07-26 literals". **That is false**, and has been since `81c0161` derived the gate's
samples from the data; Codex found it on W2, where the same file is also touched.

It is fixed **on W2 only**, on purpose. Both branches editing the same seven lines guarantees a merge
conflict in a summary block, for one fix. W2 already replaces `docs/PROMOTION.md` wholesale and is
the branch whose verdict raised it. Recorded here so the omission is a decision, not an oversight —
if W1 somehow lands first, this is the line to carry across.

## Check 4 — both measurements, read-only

Both gate files were scanned for write statements before being sent (`INSERT/UPDATE/DELETE/ALTER/
CREATE/DROP/TRUNCATE/OPTIMIZE/RENAME/REPLACE/DETACH/ATTACH/EXCHANGE`) — no matches in either.

### 4a — `origin/dev`'s gate (the DEPLOYED spec)

```text
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS
```

**The graded database is correct.**

### 4b — this branch's own gate

```text
1. │   0 │ SUMMARY  │ minutes_compared=17028 │ mismatched=177 │ max_abs_diff=39 │ peak=2887 │ MISMATCH
```

**Expected, and attributed.** This branch predates ADR 0009, and the graded database was rebuilt from
`dev`, which carries it. Re-proven by isolation today — change **two characters**, nothing else, and
the same file passes:

```text
$ diff sql/90_reconcile.sql variantA.sql
104c104
<                         if(arrayFirst(x -> x > p, p2.rs) = 0,
---
>                         if(arrayFirst(x -> x >= p, p2.rs) = 0,
108c108
<                            arrayFirst(x -> x > p, p2.rs)),
---
>                            arrayFirst(x -> x >= p, p2.rs)),

$ <variantA against sonyliv, read-only>
1. │   0 │ SUMMARY │ minutes_compared=17028 │ mismatched=0 │ max_abs_diff=0 │ peak=2917 │ PASS
```

177 → 0 from two characters rules out ADR 0016/0021/0022 and residual data damage as causes. **This
resolves itself when W2 lands**, which is why the promotion order puts wave 2 next; it is not a
defect in W1 and W1 should not be held on it a third time.

## `make ci`

```text
go mod tidy · go vet ./... · golangci-lint run ./...  → 0 issues
CGO_ENABLED=1 go test -race -count=1 ./...
  internal/config          ok 1.484s
  internal/otelemit        ok 1.951s
  internal/pipelinehealth  ok 2.108s
go build -trimpath ... -o bin/sonyliv ./cmd/sonyliv   → ok
```

(`golangci-lint` also emitted one cache warning naming a path in a deleted sibling worktree
`sc-condensed-meissner-6502`. It is a stale-cache artefact of this machine, not a finding: the run
still reports `0 issues`.)

## Rules held while answering

No write of any kind reached `sonyliv` or any Cloud database. `REBUILD_GRADED` and
`APPLY_GRADED_DESTRUCTIVE` were never set, to any value, at any point — every guard test is a
**refusal** test, and the one test that needed the guard to *fail* was run against the pre-fix script
with unroutable credentials so the failure landed in DNS. All probe files live outside the repository
and the one temporary in-repo script copy was removed in the same command that ran it.
