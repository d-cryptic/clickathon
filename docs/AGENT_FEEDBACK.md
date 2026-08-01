# Agent feedback to the operator

> **Summary:** What was awkward, what slowed the agent down, and suggestions. Appended at session end,
> ingested periodically. Newest first. **No secrets.**

## 2026-08-01 — incremental publisher tiers (ADR 0016)

- **The worktree was cut from `main`, not `dev`, and every briefed file was "missing".** The brief
  said target `dev`; the fresh worktree sat at `main`'s tip, where `sql/12_publish.sql` etc. do not
  exist. `git reset --hard origin/dev` (no local commits) fixed it, but this is the third session
  bitten by branch-vs-worktree drift — `sc worktree create` briefs should state the base the tree
  was actually cut from.
- **`.env` absent in the fresh worktree again** — same as the ADR 0013 session's note. Copying from
  the main checkout worked; `tools/env-doctor.sh` remains unbuilt and remains worth building.
- **The extraction-marker idiom (`PUBLISH_EXTRACT_BEGIN/END`) earned its keep immediately**: the
  first templated hour INSERT failed because `WHERE` cannot precede `ARRAY JOIN` — caught in a
  10-second probe against a scratch DB *before* the 8-minute harness ran. Probing each templated
  statement standalone before the full harness should be standard for future publish.sh phases.
- **The queue's reserved-ADR table was stale on arrival** (said "next free: 0015" while the brief
  said 0015 was taken). Assigning ADR numbers in the brief, as this round did, works; the queue
  needs updating in the same commit that claims a number, which this branch now does.

## 2026-08-01 — repo scaffolding

- Scaffolded from 57 verified corrections gathered pre-event. The highest-value carry-over is
  `docs/VERIFIED.md`: eleven facts that each silently waste 10–20 minutes if rediscovered live.
- `sql/05_users.sh` is deliberately a **shell script**, not `.sql`. If someone "tidies" it back to
  `.sql`, the agent user's password becomes the literal string `${AGENT_PASSWORD}`.
- Open question for the operator: LICENSE is MIT by default — confirm or switch before submission.

## 2026-08-01 — continuously updated aggregates (ADR 0013)

- **The branch was 12 commits behind `dev` and nothing said so.** The first `make reconcile` failed
  with 177 mismatched minutes and a peak of 2,887 vs 2,917 — which reads exactly like "I broke the
  model", not "my worktree is stale". Fast-forwarding fixed it. Worth a line in AGENT_WORKFLOW: on a
  parallel-agent round, `git merge --ff-only dev` before trusting any gate result.
- **The Cloud service is shared by six worktrees at once.** `make reconcile` reads a database other
  agents are actively rebuilding, so a red gate may be someone else's in-flight write. Everything here
  was proven in `sonyliv_pub` / `sonyliv_pub_ctl` for that reason. If parallel rounds continue, a
  per-agent scratch database should be the default rather than something each agent invents.
- **`.env` is gitignored and absent in a fresh worktree**, and `tools/ch` fails with a bare curl 403.
  The local container's password also differed from the one in a sibling worktree's `.env`
  (`docker inspect ch` was the only way to find it). A `tools/env-doctor.sh` that says "no .env; copy
  from X" and "local container expects password Y" would have saved 10 minutes.
- **`apply-sql.sh` refuses `--database scratch` while `.env` exports `CH_DATABASE=sonyliv`.** The
  guard is right, but every scratch-database script now needs `env -u CH_DATABASE` and that is not
  documented anywhere. Suggest mentioning it in `tools/README.md` §Which database.
- **Measuring on an unsettled part set produced a backwards conclusion.** The read-scoping A/B first
  reported the event-time window as a regression; it was a 2.9× win once merges had drained. Any
  future perf harness in this repo should `OPTIMIZE … FINAL` and average N runs before printing a
  number — `evidence/capture.sh` may be worth auditing for the same trap.
- **`sql/60_projection.sql` hard-codes `sonyliv.`** so it cannot be applied to a scratch database.
  Same defect class ADR 0010 fixed in `sql/80_content.sql`; worth a sweep for others.

## 2026-08-01 · clickstack-dashboards session

- **The worktree was cut behind `dev` while the service ran dev's model.** First reconcile run
  failed with a 2,887-vs-2,917 split that looked like a model bug and was actually branch skew.
  Suggestion: `sc worktree create` sessions targeting `dev` should start from `dev`, or
  WALKTHROUGH should say "reset onto dev before trusting any gate output".
- **"Provisioned" ≠ "renders."** The user-concurrency tiles had been silently broken since the
  `concurrent_users` rename — POST/PUT return 200 for tiles whose column no longer exists. The only
  test that catches this is executing the tile (MCP `query_tile`). Worth wiring into a check
  script before demos.
- **The max-combo trap cost the old dashboard its three breakdown tiles** (285 shown vs 1,837
  true). The arithmetic rules in ARCHITECTURE.md cover sums; "max() over a finer grain" deserved a
  line too — added to CLICKSTACK.md.

## 2026-08-01 · unseen-day rehearsal (synthetic day)

- **A green gate cannot see a wrong tie-break.** The rehearsal's sharpest lesson: the gate passed on
  all 1,080 minutes while the submitted peak MINUTE was wrong (bare argMax under a 64-minute tie).
  Value-level reconciliation needs a companion that checks the *answer we would type into the form*.
  The designed-truth generator (`tools/unseen-gen.sh`) is that companion — consider requiring it in
  the same breath as `/reconcile` before submission.
- **`sed \b` is a GNU-ism and this repo runs on macOS.** `render()` in unseen-run.sh silently
  no-opped for its entire life; only a file that legitimately failed the guard exposed it. A cheap
  pre-commit lint for `sed.*\\b` would have caught it the day it was written.
- **Comments that quote defects can re-trigger the defect's guard** (ADR 0010's comments killed
  phase 6). When a guard greps rendered SQL, strip comments first — now done, but the pattern
  generalises to every grep-a-file guard in tools/.
- **Concurrent agents + a fixed default scratch DB name is a foot-gun.** Preflight found the default
  `sonyliv_unseen` still holding the previous rehearsal's state; a literal runbook run would have
  dropped it. Suggestion: default UNSEEN_DB to `sonyliv_unseen_$(whoami or slug)` or refuse when the
  DB exists non-empty.

## 2026-08-02 · T3 runtime preprocessing (ADR 0025)

- **`build-model.sh` and `reconcile.sh` still carry bug 11.** Both source `.env` with `set -a`
  *after* reading the environment, so `CH_DATABASE=t3_preproc TARGET=cloud tools/build-model.sh`
  resolves to `sonyliv` and only the REBUILD_GRADED guard stops it — I had to replay the six stages
  by hand with `apply-sql.sh --database`. The env-capture fix that already landed in `tools/ch`,
  `apply-sql.sh` and `load.sh` should be copied into these two; until then a scratch build via env
  override is impossible and the guard is the only thing between that mistake and the graded DB.
- **T2's cruel generator had not landed** on any pushed branch when T3 needed its output. The brief
  said "coordinate by reading its output" — with nothing to read, the classifier was designed from
  the brief's four classes and self-tested with `char()`-built bytes. Suggest briefs that depend on
  a sibling worktree's artifact name a fallback explicitly, as this one implicitly required.
- **The query condition cache makes repeat sweeps look 4× cheaper than cold** (327 ms → 75 ms on the
  same statement). Anyone benchmarking "preprocessing cost" on a warm service will understate it —
  worth a line in the evidence conventions.

## 2026-08-02 · schema-drift / ADR 0024 session

- **`tools/build-model.sh` still has the bug-11 env-clobber `tools/load.sh` was fixed for.** It
  sources `.env` with `set -a` AFTER the caller's environment, so `CH_DATABASE_LOCAL=scratch
  tools/build-model.sh` silently targets whatever `.env` says — this session asked for
  `adr0024_drift` and the script TRUNCATEd `default.session_intervals` before dying on a schema
  mismatch. Local-only damage, disclosed in the 2026-08-02 worksheet; the graded DB has its own
  guard. The fix pattern already exists at the top of load.sh; build-model.sh (and a sweep of the
  other `set -a && . ./.env` tools) should adopt it. Not fixed here — outside this session's
  ownership list.
- **`tools/reconcile.sh`'s local branch ignores the database entirely** (`docker exec …
  clickhouse-client` with no `--database`, i.e. always `default`) and unconditionally overwrites
  `evidence/reconcile.txt`. Running the gate against a scratch DB means bypassing the wrapper and
  piping `sql/90_reconcile.sql` by hand. A `--database` flag matching load.sh/apply-sql.sh would
  make the gate usable in the isolation pattern every other tool now follows.
- **`tools/fetch_data.sh` overwrites the vendored spec docs' local preamble** and then warns
  "UPSTREAM SPEC CHANGED" — a false alarm on every fresh worktree (the body is unchanged; only the
  repo's own "vendored verbatim" banner is stripped). Either exclude the banner from the synced
  region or hash only the upstream body.
