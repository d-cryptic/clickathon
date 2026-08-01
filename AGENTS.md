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
arrivals. Scored against a **private ground truth** on a benchmark query set, plus an **unseen day**
released in the final hours. Full statement: [docs/PROBLEM.md](docs/PROBLEM.md).

## Where to go

| I need to… | Go to |
|---|---|
| Understand how work flows here (gates, reviews, worksheets) | [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md) |
| Understand the concurrency model and why | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Know the field names / event types / data shape | [docs/DATA_DICTIONARY.md](docs/DATA_DICTIONARY.md) |
| Write SQL the way this repo writes SQL | [docs/CONVENTIONS.md](docs/CONVENTIONS.md) |
| Know what is tested and what to avoid | [docs/TESTS.md](docs/TESTS.md) |
| Pick up the next task | [TODOS.md](TODOS.md) |
| Resume a dead session | newest file in [docs/worksheets/](docs/worksheets/) |
| Run something (query, bench, reconcile, load) | [tools/README.md](tools/README.md) |
| Know what is already **verified** vs assumed | [docs/VERIFIED.md](docs/VERIFIED.md) ← **read before trusting any ClickHouse claim** |
| Record a design decision | [docs/adr/](docs/adr/) |
| **Understand the model in depth, with diagrams** | [docs/artifacts/](docs/artifacts/) — open the newest `.html` in a browser |
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
