# ADR 0018 — One target, one database: no cross-target fallback, no server default

> **Summary:** Three layers answered "which database?" three ways. Go read `CH_DATABASE` — the
> graded Cloud database — even for local work, so `sonyliv verify -target local` 404ed; `tools/ch`
> sent no database at all locally and inherited the server default; and the deployed local schema
> had drifted (`uniq` vs `uniqExact`, `UInt64` vs `Int64` deltas) because `IF NOT EXISTS` never
> migrates. Decision: **each target owns its variables — cloud = `CH_HOST`+`CH_DATABASE`, local =
> `CH_LOCAL_URL`+`CH_DATABASE_LOCAL` — both always sent explicitly, environment beats `.env`,
> missing config dies at startup.** Drift vs intent is tabulated below; the column-diff found 4
> drifted columns, all rebuilt; **0 remain** (`evidence/target-resolution.txt`).

**Status:** accepted · **Date:** 2026-08-01
**Evidence:** [`evidence/target-resolution.txt`](../../evidence/target-resolution.txt)
**Extends** [ADR 0005](0005-heartbeat-lease-semantics.md) (which mandated `uniqExact` — the drift
this ADR repairs was a stale deployment of exactly that decision) and the bug-11 database-resolution
work in `tools/apply-sql.sh` / `tools/load.sh` (docs/SESSION-2026-08-01.md §4).

> **Scope, narrowed 2026-08-02 after Codex check 5.** An earlier wording said this ADR "promotes a
> two-script fix to the rule every layer follows". **It does not, and the claim is withdrawn.** The
> rule is fully implemented on the two layers that carry the graded target — `tools/ch` and the Go
> binary — and only partially on the other shell tools, whose LOCAL paths still inherit the server's
> default database and whose `TARGET` is honoured but not validated. The measured per-layer status is
> the addendum at the end of this file. An accurate smaller claim beats an aspirational larger one:
> the failure this ADR exists to prevent is a *confident query against the wrong database*, and a doc
> that overstates its own coverage is that failure in prose.

## Context

The same intent — "run this against local" — resolved to three different answers depending on which
layer executed it:

| Layer | Host came from | Database came from | Failure mode |
|---|---|---|---|
| Go `internal/config` | `CH_LOCAL_URL` ✓ | **`CH_DATABASE`** (= `sonyliv`, the graded Cloud DB), else literal `default` | `verify -target local` 404ed looking for `sonyliv` on localhost |
| `tools/ch` (local) | `CH_LOCAL_URL` ✓ | **nothing sent** → server default for the `app` user | worked by coincidence; broke the moment the default changed, and broke silently from any CWD other than repo root (it read `./.env`) |
| `tools/apply-sql.sh`, `tools/load.sh` | per-target ✓ | `CH_DATABASE_LOCAL` chain (bug-11 fix) — but `.env` did not define it, and `.env.example` did not mention it | fell through to `CH_DATABASE` |
| deployed local schema | — | — | `uniq`/`UInt64` where Cloud has `uniqExact`/`Int64`: a local check can disagree with Cloud for reasons unrelated to the change under test |

The stakes are not hypothetical: earlier today a mistargeted model build left the **graded**
database serving two model generations for ~2 hours. This repo's whole scoring path depends on
"which database did that command touch" having exactly one answer.

## Decision

**The resolution rule.** It is the rule for every layer; it is *implemented* on the layers the
addendum names, and the rest are open work, not a claim already met.

```
TARGET=cloud   host CH_HOST:CH_PORT    database  $CH_DATABASE        > .env CH_DATABASE        > die
TARGET=local   host CH_LOCAL_URL       database  $CH_DATABASE_LOCAL  > .env CH_DATABASE_LOCAL  > die
```

1. **A target only reads its own variables.** `CH_DATABASE` names the graded Cloud database and is
   invisible to the local target — pinned by `TestLoadLocalNeverReadsCloudDatabase`.
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
4. **`TARGET` is read from the environment on every layer; an unrecognised value dies — in
   `tools/ch` and the Go binary only.** Narrowed 2026-08-02: the other shell tools spell it
   `TARGET="${TARGET:-local}"` and then branch on `[ "$TARGET" = cloud ]`, so `TARGET=Cloud` is
   *accepted* and silently means local. Measured in the addendum. The direction of that failure is
   the safe one — a typo can only fall towards local, never towards the graded service — but it is
   still a guess, which is what this ADR says must not happen.

   *The history that produced the rule*, added 2026-08-01 after the first cut of this ADR shipped:
   `tools/ch` assigned `TARGET=local`
   unconditionally and switched to Cloud only on a positional `-c` flag, so
   `TARGET=cloud tools/ch "…"` silently queried **local** while the file's own header documented
   `TARGET=cloud (-c)` as equivalent spellings. Every other tool here (`build-model.sh`,
   `apply-sql.sh`, `reconcile.sh`) takes `TARGET=`, so `tools/ch` was the odd one out and the
   divergence was invisible at the call site. The reproduction returned
   `Database sonyliv does not exist`, which reads as the graded database having been dropped —
   it had not been; the query was simply on the wrong server. A typo like `TARGET=Cloud` now
   dies rather than falling through to local, because silently defaulting is the whole failure
   class this ADR exists to remove.
5. **Missing config dies at startup, naming the variable** — in `tools/ch` before any request; in Go
   at `config.Load`. Never a confident query against the wrong database. (This item was numbered `4`
   twice until 2026-08-02.)
6. **`.env` resolves relative to the repo root**, not the CWD (`tools/ch` used to silently lose all
   configuration when invoked from a subdirectory).
7. `CH_DATABASE_LOCAL=default` is **required** in `.env` (documented in `.env.example`).

## Intentional differences vs drift

The durable part. When local and Cloud disagree, check this table before debugging the model.

**Intentional (do not "fix"):**

| Difference | Why |
|---|---|
| Database name: local `default`, Cloud `sonyliv` | The container's initdb loads into `default`; the venue provisioned `sonyliv`. Encoded per target in `CH_DATABASE_LOCAL` / `CH_DATABASE`. |
| Local carries a subset of objects (6 tables; no serving views, hour tier, or publish machinery) | Local exists for fast iteration; tiers are built on demand by `tools/build-model.sh` / `tools/apply-sql.sh`. An absent object locally is "not built yet", not drift. |
| Local lacks two **columns** that Cloud has: `ev_raw.ingested_at`, `session_intervals.build_version` | Added 2026-08-02. Additive columns from later ADRs, applied to Cloud and not yet to the local container. Same "not built yet" case as the row above, but worth stating separately because that row says *objects* and these are columns on tables local does have. Re-measured today: **0 type differences** on every column the two DO share, so the "4 drifted, 0 remain" claim holds. |
| Users/auth: local `app` + `CH_PASSWORD_LOCAL` over HTTP :8123, Cloud `default` + `CH_PASSWORD` over HTTPS :8443 | Different security postures; both explicit in `.env`. |
| Cloud-only extra databases (`sonyliv_pub*`, `sonyliv_verify`, `sonyliv_unseen`, local `tie0014`, `csv_audit`) | Scratch/verification/publish spaces, each created deliberately by a tool that names its database. |

**Drift (found by the column diff, repaired 2026-08-01, local rebuild only):**

| Column | Was (local) | Is (both) | Damage window |
|---|---|---|---|
| `cc_minute_stateless.active_state`, `mv_stateless` | `AggregateFunction(uniq, String)` | `AggregateFunction(uniqExact, String)` | Zero **today** — at 1× cardinality (peak 2,894/min) `uniq` still answers exactly, all 3,860 minutes agreed. It starts lying silently at the 100× scale test. The type is the bug, not today's numbers. |
| `cc_minute_delta.starts`, `.ends` | `SimpleAggregateFunction(sum, UInt64)` | `…(sum, Int64)` | Local table was empty; unsigned would have corrupted ADR 0006's negative late-arrival corrections on first local build. |

Root cause of both: `CREATE TABLE IF NOT EXISTS` is a no-op on an existing table, so a git-side type
change never reaches an already-initialized local volume. Detection is one rerunnable diff of
`system.columns` across targets (commands in the evidence file); repair is DROP + re-apply the git
SQL + backfill, verified 0/3,860 minutes disagreeing with `ev_raw`.

**Known residue (owned elsewhere, flagged not fixed):** the local chains in `tools/apply-sql.sh` and
`tools/load.sh` still fall back to `CH_DATABASE` after `CH_DATABASE_LOCAL`. Dead in practice now
that `.env` must define `CH_DATABASE_LOCAL`, but the fallback steps should be deleted to match this
rule. Those files are owned by another workstream.

## Consequences

- `sonyliv verify -target local`, `tools/ch`, and the bug-11 scripts now resolve identically; the
  proof run in the evidence file shows the same command returning `default`/`sonyliv` with the same
  91,292 rows and peak 2,894 on both targets.
- A fresh clone without `.env`, or an `.env` missing a database variable, fails with a message
  naming the variable — **in `tools/ch` (before any request) and in Go (at `config.Load`)**. The
  other shell tools have no such preflight; narrowed 2026-08-02, see the addendum.
- Local reconciliation is now trustworthy: a local/Cloud disagreement means the change under test,
  not an estimator or a signedness mismatch.
- Cost: one more required variable in `.env`. Deliberate — a guessed database was the incident.

---

## Addendum — 2026-08-02 · which layers actually hold the rule, measured

Codex check 5 on promotion W1 objected that *"every layer"* overstates: several shell tools still
fall back to a server default and accept an unrecognised `TARGET`. **The objection holds.** Rather
than fix five scripts inside a promotion whose scope is the two that carry the graded target, the
claim is narrowed to what the tree does — and what it does not do is now written down instead of
implied away.

Three properties, per layer, each measured rather than read off the source:

| Layer | Dies on an unrecognised `TARGET` | Sends an explicit database — CLOUD | Sends an explicit database — LOCAL | Environment beats `.env` |
|---|:--:|:--:|:--:|:--:|
| Go `internal/config` (`sonyliv …`) | ✅ | ✅ | ✅ | ✅ |
| `tools/ch` | ✅ | ✅ `$CH_DATABASE` | ✅ `$CH_DATABASE_LOCAL` | ✅ |
| `tools/build-model.sh` | ❌ | ✅ *(via `tools/ch`)* | ✅ *(via `tools/ch`)* | ❌ |
| `tools/reconcile.sh` | ❌ | ✅ `?database=` | ❌ server default | ❌ |
| `tools/apply-sql.sh` | ❌ | ✅ `--database` | ❌ server default | ❌ |
| `tools/load.sh` | ❌ | ✅ `?database=` | ❌ server default | ❌ |
| `tools/truncation-test.sh` | n/a — pins `DB=sonyliv_trunc` | ✅ `--database "$DB"` | ✅ | ❌ |
| `tools/unseen-run.sh` | n/a — pins `$DB` | ✅ `?database=${DB}` | n/a | works around it with a sandboxed `.env` copy (lines 236-243) |
| `tools/stats` | n/a — local only | n/a | ❌ no database at all | ❌ |

### How the two ❌ columns were measured, not inferred

**Unrecognised `TARGET`.** `tools/ch` refuses; `apply-sql.sh` accepts and quietly goes local:

```text
$ TARGET=Cloud tools/ch "SELECT 1"
tools/ch: TARGET='Cloud' is not a target. Use 'local' or 'cloud' (or the -c flag). Refusing to guess — see ADR 0018.

$ TARGET=Cloud tools/apply-sql.sh <a SELECT currentDatabase() probe>
applying to LOCAL: docker exec ch
  …probe.sql ... default	26.7.1.1315
```

The tell is the banner: the script printed **LOCAL** for a value that is neither `local` nor `cloud`.

**Explicit database on the local target.** Point `CH_DATABASE_LOCAL` at a non-default local database
and ask each layer which database it actually reached. A layer that sends the database explicitly
answers `w2ans`; a layer that sends nothing answers with the server default:

```text
$ CH_DATABASE_LOCAL=w2ans tools/ch "SELECT currentDatabase()"
w2ans                                   ← explicit

$ CH_DATABASE_LOCAL=w2ans sonyliv verify -target local
… database w2ans (user app)             ← explicit

$ CH_DATABASE_LOCAL=w2ans TARGET=local tools/apply-sql.sh <probe>
applying to LOCAL: docker exec ch
  …probe.sql ... default                ← IGNORED; server default answered

$ docker exec -i ch clickhouse-client --query "SELECT currentDatabase()"     # load.sh's exact idiom
default
$ docker exec -i ch clickhouse-client --format TSV < probe.sql               # reconcile.sh's exact idiom
default	26.7.1.1315
```

`tools/ch` returning `default` in the ordinary case is *not* evidence of the same defect — it sends
`CH_DATABASE_LOCAL`, whose configured value happens to be `default`. This probe is what separates
"sent the right thing" from "sent nothing and got lucky", and it is the only way to tell them apart
from the outside.

### What this does and does not put at risk

**Not at risk: the graded database.** It exists only on Cloud, and every cloud path in the table
sends its database explicitly. No unqualified statement from these tools can reach `sonyliv`. The
2026-08-02 corruption came through `tools/publish-test.sh` — a different script, not in this
promotion, and the reason queue item **Q33** exists.

**At risk: the meaning of a local check.** A local reconcile or schema apply can silently answer from
whichever database the `app` user defaults to rather than the one under test — which is exactly the
class of "it passed locally" that this ADR was written to end. It is a correctness-of-evidence
problem, not a data-loss problem.

**Open work, named:** extend the environment-capture idiom (`ENV_DB="${CH_DATABASE-}"` before
`set -a && . .env`) and an explicit `--database` to `build-model.sh`, `apply-sql.sh`, `load.sh`,
`reconcile.sh` and `truncation-test.sh`, and give them `tools/ch`'s `TARGET` validation. Same family
as Q33. It is deliberately not done here: this promotion's scope is the two layers that touch the
graded target, and widening it would mean promoting five untested script changes on the strength of a
sentence in an ADR — the exact move check 1 exists to prevent.
