# Promotion baseline — what `main` was before any feature was promoted

> **Summary:** Measured on `main` at `c10e97d`, 2026-08-02, before the first promotion. `make ci`
> passes, but that is a weaker statement than it sounds: `cmd/sonyliv` and `internal/chdb` have **no
> test files at all** (0.0% coverage), and two safety properties we rely on do not exist here yet.
> `main`'s `tools/ch` **ignores `TARGET`** — it assigns `local` unconditionally and switches to Cloud
> only on a positional `-c`, so `TARGET=cloud tools/ch "…"` silently queries **local**. And `main`
> has **no write guard**: `tools/build-model.sh` will rebuild the graded database unchallenged. Both
> are fixed on `dev` and are exactly what promotion wave 1 carries — which is why it goes first.

**Why this file exists.** Every promotion measures a delta. Without a recorded "before", a passing
check after a promotion cannot be distinguished from a check that would have passed anyway.

---

## Build and test

```
make ci                             green
  golangci-lint                     0 issues
  go test -race ./...               all packages ok
  build                             ok (version c10e97d)
```

**Coverage — the number `make ci` green does not tell you:**

| package | on `main` | on `dev` |
|---|---:|---:|
| `cmd/sonyliv` | **0.0%** *(no test files)* | 58.7% |
| `internal/chdb` | **0.0%** *(no test files)* | 93.1% |
| `internal/config` | 77.6% | 87.9% |
| `internal/otelemit` | 19.6% | 95.7% |
| `internal/pipelinehealth` | 54.5% | 90.8% |

The ~1,363 lines of Go tests added on 2026-08-01 — including the fixture that would have caught a
parser silently reading a **passing** correctness gate as failed — are on `dev` only. So is the
false-confidence audit that sabotage-checked them and found **8 of 10 probes survived** before fixing.

## Two safety properties `main` does not have

**1 · `tools/ch` ignores `TARGET`.** It assigns `TARGET=local` unconditionally and switches to Cloud
only on a positional `-c` flag, while its own header documents `TARGET=cloud (-c)` as equivalent
spellings. Consequence: `TARGET=cloud tools/ch "…"` — the convention every other tool here uses —
runs against **local**. A reproduction on 2026-08-01 returned `Database sonyliv does not exist`,
which reads exactly like the graded database having been dropped. It had not been.

**This is why wave 1 is first.** Check 3 of the promotion gate ("run it for real, read-only") goes
*through* `tools/ch`. Validating any later feature with this version would be worthless.

**2 · No write guard on the graded database.** On `main`, `tools/build-model.sh` TRUNCATEs four
tables and rebuilds them against whatever `TARGET` says, and `tools/apply-sql.sh` applies arbitrary
DDL, with nothing asking a question first. That is the exact mechanism that, earlier on 2026-08-01,
left `sonyliv` serving **two different model generations** — minute peak 2,887 with 1,949.331 hours
against hour peak 2,917 — for about two hours until an external audit noticed.

## The graded service at baseline

Unchanged by any of this, verified read-only:

```
 session_intervals   30,323        cc_minute_delta     28,073
 cc_hour_agg         26,254        cc_user_minute      91,692
 minute peak          2,917 @ 2026-07-26 10:56    hour tier peak  2,917
 user peak            2,844        session-independent  2,894
 gate           17,028 minutes · 0 mismatched · max_abs_diff 0
```

`sonyliv` is on **pre-ADR-0016/0021/0022 shapes** — `mv_user_minute` still exists, `cc_user_minute`
is still `SharedAggregatingMergeTree`, `cc_hour_agg` has no `cube_level`. That is deliberate and
parked in [`v2.todo.md`](../../v2.todo.md) §A3; nothing served is wrong because of it.

## What "promoted" will mean against this

A feature has landed when the six checks in [`docs/PROMOTION.md`](../../docs/PROMOTION.md) pass and
the delta against the numbers above is either **zero** (for evidence, tooling and docs) or
**explained and intended** (for anything that changes behaviour). The gate result —
17,028 minutes, 0 mismatched, peak 2,917 — must be **identical** after every promotion. Movement
there is a finding, not a rounding difference.
