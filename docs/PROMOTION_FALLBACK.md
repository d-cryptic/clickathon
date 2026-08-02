# PROMOTION FALLBACK — the decision to make before the deadline forces it

> **Superseded historical plan:** `main` and `dev` were later merged; current release status is in
> Codex Validation 009. The repository-public and Team-Captain blockers in this dated plan were not
> present in the final official submission rules and must not be used.
>
> **Summary:** `main` was **186 commits / 629 files / +61,349 lines** behind `dev`, and the
> feature-by-feature gate has correctly rejected **three** promotion attempts on real defects. That is
> the gate working — but it is slow, and if it does not finish, `main` ships without almost everything
> we built. This file states the fallback **now**, while it is a considered choice, rather than at the
> deadline when it would be a panic. The recommendation is a **hard cutoff**: keep promoting
> wave-by-wave until a stated time, then merge `dev` → `main` as one commit with an honest note about
> what was and was not individually gated. **Only a human can call the cutoff time.**

---

## Where things actually stand

| | |
|---|---|
| `main` | 186 commits behind — holds the deck, the artifacts, and the promotion baseline |
| `dev` | gate green, `make ci` green, every feature merged after review |
| promotions attempted | 3 |
| promotions accepted | **0** |
| defects the gate caught | **3, all real** |

The three rejections were worth having:

1. **W1** — `GRADED_DB` was caller-overridable, defeating **both** graded-database guards.
2. **W2** — ADR 0009 claimed `any()` was gone while its own `sql/40_deltas.sql` still executed it,
   from an incomplete cherry-pick.
3. **W3** — could not *run* check 3 at all: `main`'s `apply-sql.sh` has no `--database` parser, so
   the convergence claim was unverifiable. It also corrected an attribution two prior reviews had
   agreed on.

None of those would have surfaced from a wholesale `dev` → `main` merge.

## The tension, stated plainly

**The gate is right and the gate is slow.** Waves are sequential — W3 proved that, not by argument
but by being unable to execute. Each wave is: cherry-pick → six checks → Codex validation → fix →
re-validate. Three waves remain after W1 and W2, and the evidence/docs waves are large.

**Meanwhile the risk of an unpromoted `main` is not academic.** If judging happens against `main` as
it stands, we ship a deck and a baseline document, and none of the model work, evidence, tests or
dossiers. That is a far worse outcome than promoting with less individual scrutiny.

## The fallback, and why this shape

**Keep promoting until a human-set cutoff. At the cutoff, merge `dev` → `main` as one commit** with a
commit message that says exactly which features were individually gated and which were not.

Why this is defensible rather than a retreat:

- **`dev` is not unreviewed.** Every feature on it was reviewed at merge, the gate passes on the
  graded database, `make ci` is green, and it has been through a property-test suite, 11 golden
  cohorts, an executable edge-case matrix, a cruel-data generator, and **three independent Codex
  audits** (002, 003, 004) plus two Codex promotion validations.
- **The three defects the gate found are already fixed on `dev`.** Their value has been captured; it
  does not evaporate if the remaining waves are not individually gated.
- **A fast-forward is mechanically clean** — `dev` contains all of `main`, so there is no conflict
  risk at the merge itself.

Why it is still second-best, and this must be said in the commit message: **the remaining waves would
not have received their own adversarial pass.** Three of three attempts found something. It is
unlikely the rest are clean.

## What must be true before the fallback is taken

1. **The gate passes on the graded database** at the moment of the merge — 17,028 minutes,
   0 mismatched, peak 2,917. Re-run it; do not trust the last run.
2. **`make ci` green** from a clean shell.
3. **The commit message names what was gated and what was not.** A judge or a teammate reading
   `main`'s history should be able to tell the difference without asking.
4. **`docs/PROMOTION.md`'s ledger reflects reality** — `✓` only where a wave truly passed all six
   checks including Codex validation.

## What only a human can decide

- **The cutoff time.** It depends on the submission deadline, which the orchestrator does not know.
- **Whether to take the fallback at all**, versus shipping a partially-promoted `main`.
- The final administrative contract is now tracked in `SUBMISSION.md`; this historical plan's public-
  repository and Team-Captain assumptions were retired after the official repository update.

## Recommendation

Set the cutoff at **the point where one more full wave cannot complete**. Until then, promote in
strict order — W1, W2, W3, then evidence/docs. After it, merge and be explicit in the message.

Do **not** weaken the six checks to make waves pass faster. A rejection costs a re-run; a bad
promotion to `main` costs the thing we are submitting.
