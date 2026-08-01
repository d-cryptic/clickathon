# Worksheet · 2026-08-01 · Q26 — sentinel collision in cc_hour_agg (ADR 0022)

> **Summary:** Fixed rehearsal finding R9: a real `content_id = -1` session merged into
> `cc_hour_agg`'s all-content rollup (served 2/4080 where truth was 2/3060 + 1/1020). Fix is
> structural — `cube_level UInt8` in the key marks which dims are real; sentinels are display-only.
> Load-time assertion added to `tools/unseen-run.sh`; verify probe 5 now PASS/FAIL. Reproduced,
> fixed and re-run clean in scratch DB `sonyliv_unseen_q26` (gate 1,080/0; designed truth 1,081/0;
> publisher templating re-verified live). Graded `sonyliv` untouched and unaffected (0 colliding
> rows, checked read-only). Session complete; follow-ups for non-owned files listed in ADR 0022.

**Goal** — Q26 brief: reproduce R9 in a scratch DB, fix the marker/value domain collision properly,
make the loader assert the invariant, keep the ADR-0016 canonical-INSERT contract, write ADR 0022.

**Plan → outcome**
1. `git merge origin/dev` (worktree was forked from main) — done, 51ef49f.
2. Reproduce: `tools/unseen-gen.sh` (byte-identical regen) → pre-fix run in `sonyliv_unseen_q26` →
   captured merged rows 2/4080; mechanism exact (4080 = 3060 + 1020). `evidence/unseen/adr-0022-before.txt`.
3. Fix `sql/50_hour_agg.sql`: `cube_level` in DDL key, INSERT (all GROUP BYs + window partitions),
   4 serving views (+`cube_level`, totals pin `= 0`), commented reconcile block. PUBLISH_EXTRACT
   markers and the sed anchor line byte-identical.
4. `tools/unseen-run.sh`: post-load SENTINEL AUDIT — dies on colliding values unless
   `UNSEEN_ACK_SENTINEL=1`; phase-6 status query pins `cube_level=0`. `tools/unseen-verify.sh`:
   probe 5 asserts rollup 2/3060 vs content −1 1/1020, feeds exit code.
5. Re-run: audit fires (`adr-0022-audit-fires.txt`), acknowledged run passes
   (`adr-0022-after.txt`, gate 1,080 minutes / 0 mismatched), verify exits 0.
6. Publisher path: extracted + hour-scoped-templated INSERT run live against q26 — parses,
   supersedes (12 FINAL rows before/after), idempotent values.
7. Docs: ADR 0022; RUNBOOK_UNSEEN R9 → FIXED, A10 updated. Consolidated proof:
   `evidence/unseen/adr-0022-sentinel-collision.txt`.

**Open questions / not done here (ownership)** — proposed in ADR 0022 for their owners:
`sql/85_windows.sql` cube_level pin (residual: `sum(integral)` over the two matched rows under a
collision), `tools/build-model.sh` status line + shape migration, `tools/clickstack-cloud.sh`
CUBE_TOTAL, benchmark `b13` (`cube_level = 4` instead of `content_id != -1`). The
`docs/WORKTREE_QUEUE.md` Q26 entry is left for the operator to mark done.

**How to verify from a clean tree** — `tools/unseen-gen.sh`, then
`UNSEEN_ACK_SENTINEL=1 UNSEEN_DB=<fresh name> tools/unseen-run.sh data/unseen-synthetic-raw.csv
data/unseen-synthetic-content.csv`, then `UNSEEN_DB=<same> tools/unseen-verify.sh` — probe 5 must
PASS and the verdict line must say the cube keeps content −1 separate from the rollup.

**State** — scratch DB `sonyliv_unseen_q26` dropped after evidence capture. No writes to `sonyliv`.
