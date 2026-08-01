# PROMOTION — how a feature earns its way from `dev` onto `main`

> **Summary:** `main` is what a judge reads and what we submit. `dev` carries ~115 commits across 31
> feature merges that were reviewed **only by the orchestrator that briefed them** — self-review at
> one remove. This defines the second-level gate each feature passes **individually** before it
> reaches `main`: promoted in dependency order, one at a time, each re-validated against the live
> ClickHouse Cloud service, cross-checked by a **different model** (`claude-fable-5`), with its docs
> proven current. A blanket `dev → main` fast-forward is explicitly rejected — it would promote 31
> features on the strength of one decision. **Nothing lands on `main` that has not passed all six
> checks below with committed evidence.**

**Started:** 2026-08-02. Ledger at the bottom; update it in the same commit that promotes a feature.

---

## Why not just merge `dev`

`dev` contains all of `main`, so a fast-forward is *mechanically* clean and would take one command.
That is exactly the problem: it converts 31 independent judgements into one, and the reviewer for
every one of them was the same orchestrator that wrote the brief. Two real defects today were caught
only because something re-read the work afterwards — a wrong `6,600×` ratio that had already shipped
to `main`, and a `TARGET=cloud` flag that silently queried local. Both looked fine at merge time.

So: **one feature, one gate, one commit on `main`.**

## The six checks — all must pass, evidence committed

Per feature:

**1 · Isolate.** Identify the minimal set of commits that make the feature coherent. If it cannot be
separated from another feature, **say so in the ledger and promote the smallest coherent group** —
do not pretend to a granularity the code does not have. ADR 0016 genuinely depends on ADR 0013;
splitting them would ship a publisher that references phases that do not exist.

**2 · Build and test.** `make ci` green from a clean shell — lint, `go test -race`, build. Any SQL
the feature touches applies cleanly to a **scratch** database, never the graded one.

**3 · Run it for real.** Against the live ClickHouse Cloud service, **read-only**. Re-derive the
numbers the feature claims rather than trusting the ones in its commit message. A feature whose
claimed number cannot be reproduced does not promote — that is the whole point of this gate.

**4 · The correctness gate.** `TARGET=cloud tools/reconcile.sh` must still report **17,028 minutes ·
0 mismatched · peak 2,917**. Any movement is a finding, not a rounding difference, and stops the
promotion until explained.

**5 · Cross-model validation.** A **`claude-fable-5`** agent — a different model from the one that
built and the one that merged — independently verifies the feature's claims against the live
database and the repo. Its brief is adversarial: *find the claim that does not hold.* Its verdict is
committed alongside the feature.

**6 · Docs current.** Every doc the feature touches states what is true **after** it, and no doc
elsewhere contradicts it. This is the check that failed most often today: five files still asserted
"the publisher has zero references to `cc_hour_agg`" hours after that became false, two of them
contradicting themselves a few lines apart.

## Rules that hold throughout

- **The graded database is read-only during promotion.** `REBUILD_GRADED` and
  `APPLY_GRADED_DESTRUCTIVE` stay unset. Schema changes on `sonyliv` are an operator decision and
  are parked in [`v2.todo.md`](../v2.todo.md) §A3.
- **`main` must be releasable after every single promotion**, not only at the end. If a promotion
  leaves `main` in a state we would not submit, it was too big.
- **A failed check is a finding, not a blocker to route around.** Record it, fix it on a branch, and
  re-run the gate. Do not promote with a caveat.
- **Docs-only features still pass checks 5 and 6.** Most of today's real defects were wrong *claims*,
  not wrong code.

## Promotion order — dependencies decide it, not importance

Infrastructure that everything else assumes goes first; anything that changes a serving table's
shape goes last, because it is the hardest to reverse.

| Wave | Features | Why here |
|---|---|---|
| **1 · Foundations** | ADR 0018 target resolution + the `tools/ch` `TARGET` fix; the write guards on `build-model.sh`/`apply-sql.sh` | Every later validation runs *through* these. If `TARGET=cloud` silently means local, every check above is worthless. |
| **2 · Model correctness** | ADR 0009 determinism · ADR 0011 normalisation · ADR 0014 peak-minute ties | They change the answer; everything downstream is measured against it. |
| **3 · Serving + publication** | ADR 0013 finalizer · ADR 0016 four tiers (**one group — 0016 cannot stand alone**) | The largest behavioural change on `dev`. |
| **4 · Evidence and tooling** | benchmark bundle · `make ci` + tests · scale ladder · unseen-day runbook · demo harness · ClickStack dashboards | Read-only; each independently checkable. |
| **5 · Claims and dossiers** | scope-claims pass · the 11 `doubts/` dossiers · adversarial + liveness evidence · audits · queue | Docs-only, but checks 5 and 6 still apply. |
| **6 · Shape changes** | ADR 0021 projection (already live on the service) · ADR 0022 `cube_level` | Last: they alter a serving table's shape, and their migration is parked in `v2.todo.md` §A3. |

## Ledger

`—` not started · `WIP` in a promotion worktree · `GATE n` failed at check n · `✓` on `main`

| Wave | Feature | Status | Evidence |
|---|---|---|---|
| 1 | ADR 0018 target resolution + `tools/ch` | GATE 4 | [evidence/promotion/w1/](../evidence/promotion/w1/) — checks 1–3 ✓ (code is on `chore/promotion-w1-foundations`, `fb1f98a`), check 2 re-run green on the final branch state (`02b`), check 6 ✓ after fixing one two-directional doc contradiction (`06-docs-current.txt`). Check 4 has now failed twice for two different reasons. First: the graded db was corrupt (970/17,028 mismatched; resolved by the operator rebuild, see "Incident 2026-08-02"). Second, post-rebuild: the db is byte-perfect under **dev's** gate (17,028 · 0 mismatched · peak 2,917, `04e`) but this branch's own gate reads 177/17,028 mismatched (`04d`) because the rebuild deployed dev's model **including wave-2 commit `0c0f020`** (same-second pause/resume, ADR 0009) that `main` does not carry. Spec skew, not data damage — full diagnosis in `04f-spec-skew-diagnosis.txt`. Unblocking (accept dev-gate PASS for a no-model-SQL wave, or promote wave 2's ADR 0009 first) is the orchestrator's call. |
| 1 | write guards on the graded database | GATE 4 | same bundle — checks 1–3 ✓ (`2c4ff9f`, refusals proven without ever setting an override against the service); stopped by the same check-4 spec skew. `04f` §5 states honestly that these guards would NOT have caught the 2026-08-02 unqualified-SQL incident (wrong door: `publish-test.sh` is dev-only); ADR 0018's resolution rule extended to that script (Q33) is what would. |
| 2 | ADR 0009 interval-delta determinism | — | |
| 2 | ADR 0011 query-time normalisation | — | |
| 2 | ADR 0014 peak-minute tie-break | — | |
| 3 | ADR 0013 + 0016 publication (one group) | — | |
| 4 | benchmark evidence bundle | — | |
| 4 | `make ci` + the Go test suites | — | |
| 4 | scale ladder (ADR 0020) | — | |
| 4 | unseen-day runbook + tools | — | |
| 4 | demo harness | — | |
| 4 | ClickStack dashboards (7 / 53 tiles) | — | |
| 5 | scope-claims + `doubts/` + audits | — | |
| 6 | ADR 0021 projection | — | |
| 6 | ADR 0022 `cube_level` | — | |
