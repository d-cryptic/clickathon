# AGENTS.md — the router

> **Summary:** Click-a-thon India 2026 · **SonyLIV — foreground-only concurrency at streaming scale**.
> ClickHouse is the primary datastore; ClickStack is the OSS integration. This file only *routes* — it
> tells you which doc, tool, agent or command to reach for. It is an index, not a manual. Read
> [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md) before your first change, and
> [docs/CONVENTIONS.md](docs/CONVENTIONS.md) before writing SQL.

## The problem, in one paragraph

Count how many viewers are **actively watching** at each minute — excluding backgrounded, paused and
heartbeat-missing periods — from session start/end plus 1-minute heartbeats, over a serving layer fast
enough for dashboard queries and update-friendly enough to absorb still-open sessions and late
arrivals. Judges spot-check concurrency against raw events; the released unseen data requires peak
and average minute/hour/day results with filters, latencies and pipeline evidence. Full statement:
[docs/PROBLEM.md](docs/PROBLEM.md).

## Where to go

**What is actually left? [REMAINING.md](REMAINING.md)** — verified against the live system, not
remembered. Most of `TODOS.md` is stale.

**Just waking up, or picking this up cold? Read [HANDOFF.md](HANDOFF.md) first** — what is blocked,
what only a human can do, and where the promotion gate stands.

**New here, or resuming after a break? Read [WALKTHROUGH.md](WALKTHROUGH.md) first** — what is built,
what is verified, what is broken, and what is still missing, in one page.

| I need to… | Go to |
|---|---|
| Understand how work flows here (gates, reviews, worksheets) | [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md) |
| **Understand the whole problem from scratch, in plain English** | [docs/EXPLAINER.md](docs/EXPLAINER.md) — the ask, what is really in the data, and why the obvious approach is wrong |
| **Answer "which sessions count, and what does it cost me when you are wrong?"** | [docs/BUSINESS_RULES.md](docs/BUSINESS_RULES.md) — the inclusion ledger, the cost of error in both directions, decision→tier mapping, and a straight answer on billing |
| Understand the concurrency model and why | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| **Answer "what about sessions that are still open?"** | [docs/LIVE_INTERVALS.md](docs/LIVE_INTERVALS.md) — the live edge under-reports **−14.8%** and is exact beyond **240 s**; labelling proposal in [ADR 0029](docs/adr/0029-provisional-and-final-buckets-labelled-off-the-watermark.md) |
| Know the field names / event types / data shape | [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) |
| Write SQL the way this repo writes SQL | [docs/CONVENTIONS.md](docs/CONVENTIONS.md) |
| **Set up the Go toolchain / write Go here** | [docs/GO.md](docs/GO.md) — `direnv allow`, then `make ci` |
| Know what is tested and what to avoid | [docs/TESTS.md](docs/TESTS.md) |
| **Check the model against answers it did not compute** | [docs/GOLDEN.md](docs/GOLDEN.md) — closed-form, statistical and degenerate cohorts plus the organiser file as a regression pin. `tools/golden-gen.sh` |
| Pick up the next task | [TODOS.md](TODOS.md) |
| **Spawn the next worktree** | [docs/WORKTREE_QUEUE.md](docs/WORKTREE_QUEUE.md) — prioritised, brief-ready, with ADR numbers pre-assigned |
| **Read the cross-model audit** | [docs/codex-validation/](docs/codex-validation/) — Codex reviewing our claims, not our code |
| Resume a dead session | newest file in [docs/worksheets/](docs/worksheets/) |
| Run something (query, bench, reconcile, load) | [tools/README.md](tools/README.md) |
| **Know what every dashboard panel shows** | [docs/CLICKSTACK_DASHBOARDS.md](docs/CLICKSTACK_DASHBOARDS.md) — 6 dashboards, 41 tiles, captured live |
| **Inspect hosted-panel SQL, metrics, schema and lineage to raw** | [docs/DASHBOARD_PROVENANCE.md](docs/DASHBOARD_PROVENANCE.md) — lazy, capped, deployed live |
| **Bring up ClickStack / see the concurrency chart** | [docs/CLICKSTACK.md](docs/CLICKSTACK.md) — `make stack-up && make clickstack` |
| **See ClickStack observing OUR pipeline (watermark lag, build timing, reconcile gate)** | [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) — `sonyliv observe -target cloud` |
| **Alert on concurrency decline — and tell apart ended / broken / boring** | [docs/DECLINE_ALERTING.md](docs/DECLINE_ALERTING.md) — the spec's optional item. 3 live alerts; the discrimination is the deliverable, and one of the three classes is shipped **unvalidated** and says so |
| Know what is already **verified** vs assumed | [docs/VERIFIED.md](docs/VERIFIED.md) ← **read before trusting any ClickHouse claim** |
| **Answer "how does this behave at 100×?"** | [evidence/scale.txt](evidence/scale.txt) — measured at 1×/10×/100×, and what breaks first. Regenerate with `tools/scale-test.sh` |
| **Answer the organiser's four "design decisions to confirm"** | [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md) — session timeout, lateness tolerance, window size, freshness. Three decided; **lateness is the open one** |
| **Change a tuned constant (gap, tail, unclosed-pause, point-activity, publisher bounds)** | [policy/model.policy](policy/model.policy) — the ONE declaration. Edit it, run `tools/policy.sh gen`, re-run the gate. Never edit `sql/01_policy.sql` (generated) and never re-add a literal; `tools/policy.sh check` fails both. [ADR 0032](docs/adr/0032-one-versioned-policy-declaration-read-by-every-consumer.md) |
| Record a design decision | [docs/adr/](docs/adr/) |
| **Decide whether the headline peak is 2,917 or 2,927** | [ADR 0031](docs/adr/0031-point-activity-user-attribution-and-the-densify-recipe.md) — the only open question that moves a submitted number. Both readings measured, gate green at each; needs an **operator sign-off**, not more engineering |
| **Understand the whole solution in one page, with animated diagrams** | [docs/artifacts/2026-08-02-solution-atlas.html](docs/artifacts/2026-08-02-solution-atlas.html) — **start here.** Lineage, algorithm, model, query path, updates, scale, evidence and the disclosed limits. Self-contained, opens offline, no JavaScript. Retires the old `solution-explainer` |
| **Present at a mentor checkpoint** | [docs/artifacts/2026-08-01-mentor-checkpoint.html](docs/artifacts/2026-08-01-mentor-checkpoint.html) — 11 diagrams: what we show, explain, and need answered |
| **Understand the model in depth, with diagrams** | [docs/artifacts/](docs/artifacts/) — the 4-part deep dive: `deep-1-data` · `deep-2-model` · `deep-3-correctness` · `deep-4-scale-ops` |
| Know what we must **ask a mentor** (and what we assumed meanwhile) | [docs/MENTOR_QUESTIONS.md](docs/MENTOR_QUESTIONS.md) ← **every unanswered one is a silent-failure risk** |
| **Ask a mentor the questions that carry measured evidence** | [doubts/](doubts/) — evidence + exact wording + a decision table per answer. `02` is worth **9.7%** of our headline number |
| **What happened in the last session, and every bug it found** | [docs/SESSION-2026-08-01.md](docs/SESSION-2026-08-01.md) |
| **Run the unseen day** | [docs/RUNBOOK_UNSEEN.md](docs/RUNBOOK_UNSEEN.md) — read BEFORE the data drops |
| **Know why a half-built model can no longer be served** | [ADR 0034](docs/adr/0034-generation-pinned-serving-surface.md) — the generation-pinned serving surface. The 2026-08-02 doubling reproduced (5,834) and defeated (2,917) in [evidence/generation-pinning/](evidence/generation-pinning/); `tools/build-generation.sh` |
| **Understand how aggregates stay current (the incremental publisher)** | [ADR 0013](docs/adr/0013-continuous-publication-by-incremental-finalizer.md) — `make publish`, proven in [evidence/publish.txt](evidence/publish.txt) |
| Observability / what we emit | [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) |
| **Edit or rebuild the submission deck** | [deck/checkpoint1/README.md](deck/checkpoint1/README.md) — source `deck/checkpoint1/deck.html`, `deck/checkpoint1/build.sh` → `deck/checkpoint1/deck.pdf` |
| Leave feedback for the operator | [docs/AGENT_FEEDBACK.md](docs/AGENT_FEEDBACK.md) |

## Doc conventions

- **The first 7 lines of every doc are a detailed summary**, so `grep -rl "<concept>" docs/` then reading
  only the head finds the right file. Keep that invariant.
- A change that outdates a doc **updates the doc in the same commit**. Stale docs are worse than none.
- Prefer many small system docs over one monolith.

## Agents, skills, commands

Defined in [.claude/](.claude/) — `agents/` (subagents with their own briefs), `skills/` (packaged
procedures), `commands/` (slash commands). Start with `/reconcile` and `/bench`; they are the two that
decide whether we score.

**Official ClickHouse skills are vendored** in [.claude/skills/vendor/](.claude/skills/vendor/) from
[ClickHouse/agent-skills](https://github.com/ClickHouse/agent-skills) (Apache-2.0): the **31
best-practice rules**, the architecture advisor, the ClickStack OTel collector guide, and the
`clickhousectl` workflows. **Cite them** — "Per `schema-pk-cardinality-order`…" — when making a schema
or query call. They already overturned one of our own choices; see
[ADR 0002](docs/adr/0002-order-by-time-bucket-then-platform.md).

## Non-negotiables

1. **Correctness before speed.** Every model change re-runs `/reconcile` against raw. A fast wrong answer
   scores zero — foreground-only means foreground-only.
2. **Build for the unseen day**, not the file we have. See the traps in
   [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md#traps).
3. **No credentials in git.** Everything through `.env` (gitignored) — see [.env.example](.env.example).
4. **No hand-computed answers.** Benchmark output must come from the pipeline with query-log evidence.
