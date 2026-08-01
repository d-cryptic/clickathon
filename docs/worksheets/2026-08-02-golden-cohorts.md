# Worksheet — V1 golden cohorts (2026-08-02)

> **Summary:** Build golden datasets whose answers are known independently of our SQL (closed-form,
> statistical with stated tolerances, degenerate, plus the organiser's file pinned at 30,323 iv /
> 1,978.1 h / peak 2,917), run the real sql/30+40 pipeline on each in a LOCAL `golden_*` scratch DB,
> and diff. Deliverables: `tools/golden-gen.sh`, `evidence/golden/`, `docs/GOLDEN.md`. Any
> disagreement is THE FINDING — report, never fix sql/. Session started on Fable 5, handed to
> Opus 5 mid-task at operator request. **DONE: 11 cohorts run — 10 PASS, 1 KNOWN-DIVERGENCE
> (degen-lone-event), 0 FAIL.** Results in `docs/GOLDEN.md`, log in `evidence/golden/run-20260802.txt`.

## Goal (from the operator brief, V1)

Multiple cohorts of golden datasets, each with an analytically known answer; a runner diffs the
model against every cohort; `docs/GOLDEN.md` tabulates cohort → expected → actual → verdict with
tolerances stated for the statistical ones.

Ownership: `tools/golden-gen.sh` (new), `evidence/golden/` (new), `docs/GOLDEN.md` (new).
Do NOT touch `tools/cruel-gen.sh`, `tools/unseen-gen.sh`, `tools/spike-test.sh`,
`tools/timespan-gen.sh`, or any `sql/` file.

**The rule that makes it worth anything:** expected answers NEVER come from our SQL — closed form,
or `tools/reference_interpreter.py` (model_compat mode reproduces the graded headline exactly).

## Hard constraints

- 🔴 NEVER write to `TARGET=cloud` / database `sonyliv` (graded, corrupted twice already).
  No `make model`, `build-model.sh`, `publish.sh`, no `REBUILD_GRADED`/`APPLY_GRADED_DESTRUCTIVE`.
- Everything in a LOCAL scratch DB named `golden_*` via `CH_LOCAL_URL` only
  (`tools/property-test.sh` is the safety pattern being mirrored).
- Branch `sc-diamagnetic-cooper-14d5`, merges to `dev`, never push `main`.
  Commits `<type>: <description>`, no co-author lines.

## Progress so far

1. ✅ `git fetch origin && git merge origin/dev` — merge committed (`26d4091`).
2. ✅ `.env` copied from `~/Developers/personal/clickathon-project/.env` (worktrees ship without it).
   Local ClickHouse answers `Ok.` on `$CH_LOCAL_URL/ping`.
3. ✅ Recon done: headline watch-hours = `sum(dateDiff('second', interval_start, interval_end))`
   over `session_intervals FINAL` (tools/reconcile.sh:78). sql/30 + sql/40 are single statements —
   property-test.sh already sends them over HTTP to a scratch DB; golden-gen.sh does the same.
   Raw CSV lives ONLY in the main checkout: `~/Developers/personal/clickathon-project/data/`.
4. ✅ `tools/golden-gen.sh` WRITTEN, **not yet executed, not yet chmod +x, nothing committed**.
   10 synthetic cohorts + organiser regression cohort; writes `evidence/golden/run-<seed>.txt`
   and regenerates `docs/GOLDEN.md` (full file) at the end of a full run.

## Cohort design (as implemented in golden-gen.sh)

| Cohort | Construction | Expectation source |
|---|---|---|
| closed-staircase | 60 sess × 600 s beats/30 s, staggered 60 s | arithmetic: peak 12, watch 60×660 s = 11.0 h, full curve |
| closed-blocks | 8 sess × 1800 s, staggered 300 s | arithmetic: peak 7, watch 8×1860 s |
| closed-pause | 10 sess, pause@+300 resume@+600, in-pause beats every 100 s keep the run whole | arithmetic: 2 iv/sess, watch 10×1560 s, 4-minute zero hole (min 6–9) |
| stat-exponential | Poisson 2/min × 6 h, D = 5+Exp(1200 s), final beat at t0+D | N·(5+1200+60); tol 4θ√N + N·1 s; Little λ·E[span], tol 4√L·√(2W/T) |
| stat-uniform | Poisson 1/min × 4 h, D ~ U(600,1800) integer | N·1260.5; sd √((1201²−1)/12); same tolerance shapes |
| degen-empty | zero sessions | 0 everywhere, pipeline must not error |
| degen-one | one session, 300 s | 1 iv, 360 s, peak 1, 7 minutes |
| degen-same-start | 200 identical sessions, same instant | peak 200 flat, watch 200×660 s |
| degen-dup-rows | one session's rows ×5, same sid | identical to one copy (set-of-instants) |
| degen-lone-event | one event | SPEC says [t, t+60]; shipped sql/30 drops it → verdict KNOWN-DIVERGENCE (open point-activity finding, evidence/property/failure-P1-*) |
| organiser-file | the delivered CSV | pins 30,323 iv / 1,978.1 h / peak 2,917 @ 2026-07-26 10:56, re-derived by reference_interpreter model_compat; then model must match |

Key mechanics: tail +60 s only when a segment ends at run end; end-on-boundary minute is INCLUSIVE
(C7); interval1 of closed-pause ends AT the pause instant (no tail — run continues). Statistical
cohorts avoid lone-beat sessions by construction (min duration 5 s, beat at t0 and t0+D).

⚠️ `evidence/reconcile.txt` on dev currently records the graded DB FAILING its own gate
(970 mismatched minutes, three tier vintages serving three answers — see memory + GRADED_INVENTORY).
The organiser pins deliberately come from the last GREEN reconcile + interpreter, NOT from Cloud.

## What actually happened (Opus 5 leg, 2026-08-02)

**One generator bug, then clean.** The tunable-drift guard read the wrong file: it regex'd
`HEARTBEAT_GAP_S\D+(\d+)` against `sql/10_intervals.sql`, which only *documents* the tunables in
prose — the match captured `99` out of "inter-arrival p99 of 49s" and would have aborted every run
with a bogus `GAP_S=99 != 150`. The values that actually execute are `150 AS GAP_S` / `60 AS TAIL_S`
in `sql/30_build_intervals.sql`. Fixed in golden-gen.sh to assert both constants against the code
(and to fail loudly if either alias disappears), since every closed-form expectation is arithmetic
on those two numbers. No other change was needed — arithmetic, tolerances and conventions were right
first try, including the two cohorts flagged as likeliest to be wrong.

**Results — `tools/golden-gen.sh`, db `golden_v1`, seed 20260802, exit 0:**

| | |
|---|---|
| 9 synthetic cohorts | **PASS**, exact — intervals, watch seconds and the *entire* per-minute curve |
| `degen-lone-event` | **KNOWN-DIVERGENCE**, as designed — model 0 iv / 0 s, spec 1 iv / 60 s |
| `organiser-file` | **PASS** — interpreter re-derives the pins (`CONFIRMED`) *and* the scratch-DB model reproduces them: 30,323 iv · 1,978.1 h · peak 2,917 @ 2026-07-26 10:56, exact to the second |

The organiser cohort passing is the load-bearing one: dev HEAD's model, run locally on the delivered
file, still lands on the pinned headline — so nothing in the merged work moved it, and the harness is
calibrated against a number it did not compute. Statistical cohorts landed well inside their stated
4σ bands (expo +6.6 h on ±35.0 h; uniform +2.4 h on ±6.0 h; Little's law +1.37 on ±9.7 and +0.82 on
±8.2) — comfortable, and deliberately not tightened, because a band that only just holds on one seed
is a flaky gate.

**No new findings.** The single divergence is the already-open point-activity one
(`evidence/property/README.md` §finding 1, priced on the real file at peak 2,917 → 2,927 and +5.0 h).
`sql/` was not touched.

## Next steps (in order) — all done

1. ✅ `chmod +x`, `--skip-organiser` run: 9 PASS + 1 KNOWN-DIVERGENCE in 4.6 s after the guard fix.
2. ✅ Full run with the organiser cohort (~4 min: 905,558 rows through the interpreter, then
   `tools/load.sh --database golden_v1 --replace` and the real sql/30+40).
3. ✅ `docs/GOLDEN.md` regenerated and checked — 7-line summary head, tolerance rationale, the
   divergence kept visible with its price.
4. ✅ Committed with `tools/golden-gen.sh` + `evidence/golden/` + `docs/GOLDEN.md` + this worksheet,
   plus the AGENTS.md router row (the judgment call: taken — the doc is unreachable without it).
5. ✅ Branch pushed. No PR to main; merges to `dev`.
6. ✅ Operator feedback appended to `docs/AGENT_FEEDBACK.md`.

## How to verify

- `tools/golden-gen.sh` exits 0 with every synthetic cohort PASS except degen-lone-event
  (KNOWN-DIVERGENCE — expected, documented divergence, not a failure).
- Organiser cohort: interpreter confirms pins AND scratch-DB model reproduces
  30,323 / 1,978.1 h / 2,917 exactly. If the model DISAGREES with the pins locally, that is a
  REAL FINDING (dev HEAD moved the model) — report it in GOLDEN.md, do not fix.
- `git diff --stat` touches only: tools/golden-gen.sh, evidence/golden/*, docs/GOLDEN.md,
  docs/worksheets/2026-08-02-golden-cohorts.md, .env is gitignored, nothing in sql/.

## Open questions

- None blocking. Tolerance derivations are stated inline in golden-gen.sh and GOLDEN.md; if the
  operator wants tighter statistical bounds, raise N or lower z in one place.
