# Agent feedback to the operator

> **Summary:** What was awkward, what slowed the agent down, and suggestions. Appended at session end,
> ingested periodically. Newest first. **No secrets.**

## 2026-08-01 — repo scaffolding

- Scaffolded from 57 verified corrections gathered pre-event. The highest-value carry-over is
  `docs/VERIFIED.md`: eleven facts that each silently waste 10–20 minutes if rediscovered live.
- `sql/05_users.sh` is deliberately a **shell script**, not `.sql`. If someone "tidies" it back to
  `.sql`, the agent user's password becomes the literal string `${AGENT_PASSWORD}`.
- Open question for the operator: LICENSE is MIT by default — confirm or switch before submission.
