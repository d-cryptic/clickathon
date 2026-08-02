# ORCHESTRATION — who does what, and why the lineages are split that way

> **Summary:** Work runs across two model lineages on purpose. **Opus 5 builds** — it holds the repo's
> conventions and history. **Codex validates** — check 5 of `docs/PROMOTION.md`, because the failure
> we are guarding against is a *shared blind spot*, and two checkpoints of one family share more of
> those than two families do. That is not a theory here: Codex has now found **four real defects that
> Claude-lineage review missed**, including two in the same hour — a caller-overridable
> `GRADED_DB` that disabled both graded-database guards, and an incomplete cherry-pick that made an
> ADR's determinism claim false on its own branch. Both had passed our own review.

**Established:** 2026-08-02, mid-promotion.

---

## The split

| lineage | role | why |
|---|---|---|
| **Opus 5** | build, measure, promote | carries the repo's conventions, prior ADRs and the reasoning behind them |
| **Codex** | **check 5** — adversarial validation of every promotion | different training lineage, so different blind spots. Its brief is *"find the claim that does not hold"*, never *"confirm this"* |

**A promotion is never validated by its own lineage.** An Opus-built feature gets a Codex check-5;
the reverse would also hold if Codex built something.

## The receipts — what cross-lineage validation has actually caught

| finding | who missed it | severity |
|---|---|---|
| Split model generations on the graded DB | our own review, for ~2 h | **P0** — served two answers at once |
| Unguarded write path on `build-model.sh`/`apply-sql.sh` | our own review | **P0** — later caused the corruption it predicted |
| `GRADED_DB` caller-overridable, defeating **both** guards | **two** Claude passes | high — a guard whose subject the caller controls is not a guard |
| W2's ADR 0009 claim false on its own branch (incomplete cherry-pick left `any()` executable in `sql/40_deltas.sql`) | the promoting agent | high — a promoted ADR asserting something its own tree disproves |

The last two arrived within an hour of each other, from two independent Codex validators, on two
different promotions. Neither was a style complaint.

## Levels of delegation, and when each is right

**`sc` worktrees** — isolated branch, own session, own model. For anything that writes files or runs
long. Every brief carries the same non-negotiables: step-zero `git merge origin/dev`, the graded-database
prohibition, an explicit ownership list, and centrally-assigned ADR numbers.

**Native subagents** — read-only fan-out where the conclusion matters and the file dump does not.

**The orchestrator (this session)** — merges, resolves conflicts, sizes findings before prioritising
them, and holds the ADR/`doubts/` number registry. It does **not** self-approve its own promotions;
that is what check 5 is for, and it has now been proven necessary twice.

## Rules that exist because breaking them cost us

1. **One agent per file.** Ownership lists are exclusive. Two agents in one state machine is worse
   than a one-session delay.
2. **Numbers are assigned centrally.** Three agents once independently created ADR 0009; repairing it
   touched ten files. `doubts/06` collided the same way and was caught only at merge.
3. **Never close a worktree without checking its work is merged or pushed.** `tools/close-worktree.sh`
   enforces it — written after six were batch-closed on a per-batch check, and after one agent's
   session ended with 808 uncommitted insertions on disk.
4. **Size a finding before prioritising it.** Q34 looked like an invariant violation and is worth
   ±1 on 82 cells; Q35 looked minor and moves the peak by 10. Neither was obvious from its title.
   The 28 first published for Q34 was itself a mis-sizing — a dense table inner-joined to a sparse
   one — so *check how a finding was sized* before trusting the size (ADR 0031).
5. **A refusal is the process working.** W1 refused twice and was right twice; both Codex validators
   returned DO NOT PROMOTE and both were right. Do not weaken a check to make a promotion pass.
