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
