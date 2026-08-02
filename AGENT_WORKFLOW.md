# AGENT_WORKFLOW — how work flows here

> **Summary:** 21 hours of real build time against a ~09:00 Sunday effective freeze. Work moves
> research → model → verify → optimise → evidence. The gate that matters is `/reconcile`: no model
> change lands until the serving layer matches raw. Every hour boundary must leave something
> demoable. Worksheets in `docs/worksheets/` are the handoff contract; commit one before you stop.

## The loop

```
 pull a task from TODOS.md
   └─ change the model / query / pipeline
       └─ /reconcile          ← GATE. non-zero delta = revert or fix, nothing else proceeds
           └─ /bench          ← capture latency + bytes read
               └─ commit with the evidence file
                   └─ update the doc the change outdated, IN THE SAME COMMIT
```

## Gates

| Gate | When | Blocks |
|---|---|---|
| `/verify-env` | after any `compose up` or Cloud change | everything — a failed init script leaves a healthy-looking, half-built DB |
| `/reconcile` | after **every** model change | commit |
| `/bench` | before every demo rehearsal and the unseen run | the deck numbers |
| `correctness-auditor` | before submission | submission |

## Scoring reality (drives priority)

1. **Correctness** under judge spot-checks against raw events — foreground-only means foreground-only.
2. **Query performance** — judges look at what queries *read*, not just elapsed time.
3. **Update handling** — open sessions and late heartbeats absorbed incrementally, not by rebuild.
4. **Design quality** — you must be able to defend the trade-offs out loud.
5. **The unseen day** — carries significant weight. **No pipeline evidence, no credit.**

Note what is *not* on that list: a polished frontend. The statement puts it out of scope. A minimal
concurrency chart is enough. Spend the time on the model and the serving layer.

## Rules

- **Correctness before speed, always.** A fast wrong answer scores zero.
- **Build for the unseen day**, not the file we have. See the traps in `docs/DATA_DICTIONARY.md`.
- **No hand-computed answers.** Everything through the pipeline, with query-log evidence.
- **A change that outdates a doc updates the doc in the same commit.**
- **Never push to `main` from an autonomous run.** Branch, gate, human-merge.
- **Record trade-offs in `docs/adr/` as you make them** — "design quality" is a scored criterion and
  reconstructing the reasoning at hour 20 does not work.

## Session end

Write `docs/worksheets/<date>-<slug>.md` (goal, progress, open questions, next step, how to verify),
append anything awkward to `docs/AGENT_FEEDBACK.md`, and tag the commit.
