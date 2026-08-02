# Worksheet — publisher crash & concurrency safety (Q8–Q11, ADR 0019)

> **Summary:** Reproduced all four publisher state-machine defects on a Cloud scratch database
> (Q8 orphaned claim + resume-BV self-delete, Q9 concurrent double-apply serving 2X′−X, Q10
> same-millisecond suppression, Q11 unmonitored retention deadline), then fixed them: `claiming`
> intent + rollback sweep, pinned build_version on resume, a lease with per-phase fencing,
> `(marked_at, insert_id)` pair identity, retention-headroom columns. Proven by publish-test.sh
> PHASES 12–15. Branch sc-coupled-cryostat-60b1 → dev. Nothing was run against `sonyliv`.

**Session** 2026-08-01/02 · worktree `sc-coupled-cryostat-60b1` · base merged `origin/dev` @ 54cf44c
**Owns** `tools/publish.sh`, `tools/publish-test.sh`, `sql/12_publish.sql`, `docs/adr/0019-*.md`

## Goal

Every one of Q8–Q11 either fixed with a reproducing test that fails before and passes after, or
documented with the reproduction that showed it was not real. ADR 0019 records what is atomic,
idempotent, fenced, and — the valuable part — what is still not guaranteed.

## What happened, in order

1. **Merged `origin/dev` first** (the brief's step zero — the worktree forked from `main`).
   ADR 0016 had just rewritten the state machine: 7 phases, `cc_user_minute` replaceable.
2. **Reproduced all four defects** in `sonyliv_q8scratch` (70,830-event slice, 467 sessions):
   - Q8a: killed between consumed-insert and `claimed` mark → batch orphaned forever,
     `pending_sessions = 0`, serving empty, everything green.
   - Q8b (found while reproducing Q8, worse than the brief's version): resume after `derived`
     recomputed BV → prune deleted the crashed run's own derivation → session vanished from all
     four tiers.
   - Q9: two publishers with injected holds both claimed the same marking → probe minute
     15 → 17 where truth was 16; both runs committed. Unrepairable without a rebuild.
   - Q10: same-`marked_at` markings, slower insert visible after the faster was consumed →
     suppressed forever, `pending_sessions = 0`. (`initialQueryID()` verified per-insert-constant
     inside an MV on 26.2.1.525 before designing the fix.)
3. **Fixed** in `sql/12_publish.sql` + `tools/publish.sh` (see ADR 0019 for the full ledger):
   intent-first claim + `recover_claims` rollback; batch derives FROM the consumed set; BV pinned
   in the `claimed` mark (`bv=N` note) and reused on resume; `cc_publish_lease` with
   newest-wins deterministic tiebreak, `select_sequential_consistency=1`, per-phase `lease_beat`;
   pair identity + 900 s claim lookback; `retention_*` columns + `lease_holder` in
   `v_cc_publish_lag`; `preflight_schema` refuses pre-0019 schemas with migration instructions.
4. **Extended `tools/publish-test.sh`**: PHASE 12 (16-point crash matrix), 13 (two publishers,
   lease serializes, +1 not +2), 14 (same-ms pair identity), 15 (retention alert). Fault hooks
   `PUBLISH_CRASH_AT` / `PUBLISH_SLEEP_AT` in publish.sh, inert unless set; injected crashes keep
   the lease held so recovery must win it honestly (TTL).
5. **The crash matrix caught a fifth defect the fix itself had inherited**: ADR 0013's
   `insert_deduplication_token` does NOT drop a replayed `INSERT SELECT` into the shared delta
   table — `system.query_log` showed the crash rounds' negate and emit each finishing TWICE with
   `written_rows > 0`, and the served number double-counted by exactly one viewer. The token was
   the only protection on the two append-only statements. Resume now decides negate/emit replays
   from the server's own query log (`stmt_landed`: wait out `system.processes`, flush, check for
   a recorded finish); the tokens remain attached but carry no load. Every other statement is
   replay-safe by construction (pinned BV + Replacing / idempotent DELETE / versioned rewrite).
6. **Full harness run** → `evidence/publish.txt` (all PHASES 0–15; every `differing` row 0).
   Also fixed in passing: the harness's served-minutes check now compares running sums over the
   union of minutes — the *_total views emit rows only for minutes present in `cc_minute_delta`,
   so a membership join miscounted correct net-zero correction minutes as differences.

## Decisions & gotchas (for whoever resumes)

- `tools/ch` ignores `TARGET` — use `tools/ch -c` for Cloud (Q16, another agent owns it).
- `.env` is not in fresh worktrees; copy from `~/Developers/personal/clickathon-project/.env`.
- DETACH TABLE is refused on Cloud shared databases — the Q10 repro DROPs + re-applies the MV.
- **Do not inject heartbeats onto real sessions and expect the interval to move.** Every session
  in the complete file carries a `VideoSessionEnd`, and beats after a closer (end OR pause) are
  absorbed without extending coverage (ADR 0007/0009) — worse, the re-derivation retracts the
  60 s tail to end AT the closer once post-end beats exist, so the end moves *backwards*. Two
  drafts of the ADR 0019 phases failed on this. PHASES 12–14 therefore use synthetic
  heartbeat-only probe sessions (`adr19-*-probe`, placed after 11:30 in a quiet region): no
  closer ever, so the published end is always last-beat + 60 s, deterministically.
- The `*_total` minute views omit minutes with no delta rows; probe running sums from
  `cc_minute_delta` directly.
- Lease reproduction needs `PUBLISH_LEASE_TTL_S=6 PUBLISH_LEASE_SETTLE_S=1` or the recovery
  waits a full minute per crash point.

## Not done here (other agents' files — flagged, not edited)

- ADR 0013/0016 consequence lines still say Q8–Q10 are open; now closed by ADR 0019.
- `docs/OBSERVABILITY.md` / `sonyliv observe`: emit `retention_alert`, `retention_headroom_s`,
  `pending_sessions` as gauges (ADR 0019 decision 7 has the wiring intent).
- `docs/TESTS.md`: add PHASES 12–15; `docs/WORKTREE_QUEUE.md`: mark Q8–Q11 done.
- `sonyliv` (graded) still has pre-0019 objects; migration is documented in `sql/12_publish.sql`
  and enforced by the publisher's preflight.

## Operator feedback (would normally go to docs/AGENT_FEEDBACK.md — shared file, not touched)

- The brief's "reproduce before fixing" rule caught a defect the inspection missed (Q8b) —
  keep that rule.
- Scratch DB `sonyliv_q8scratch` was dropped at session end.

## How to verify

    tools/publish-test.sh          # ~15 min; PHASES 12–15 are the ADR 0019 proof
    git log --oneline -5           # fix + test + ADR commits
