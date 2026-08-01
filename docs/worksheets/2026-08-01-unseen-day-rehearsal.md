# Worksheet — unseen-day rehearsal on a manufactured day (Q18)

> **Summary:** Rehearsed `docs/RUNBOOK_UNSEEN.md` literally against a SYNTHETIC day
> (`tools/unseen-gen.sh`, 2026-08-15, 6,887 events, every trap designed in, per-minute answer known
> analytically). Found 10 defects (R1–R10): phase 6 died on a clean day (BSD sed `\b`, comments
> tripping the guard), the submitted peak minute was WRONG under a tie with a green gate (ADR 0014
> not applied), phase 8 had drifted from the rewritten gate. All fixed in `tools/unseen-run.sh`;
> runbook rewritten from measurements; gate + designed truth both green (1,081 minutes, 0 mismatch,
> 54 s). Evidence: `evidence/unseen/rehearsal.txt`. Scratch DB `sonyliv_unseen_q18` dropped.

**Goal** — execute the never-fully-trusted unseen-day runbook on a day that is *not* a slice of the
delivered file; time it; find where it lies; rewrite it.

**State: DONE.**
- `tools/unseen-gen.sh` — deterministic generator (seed 20260815); designed truth is a third
  implementation of the counting spec (Python sets vs arraySplit vs window functions).
- `tools/unseen-verify.sh` — designed-truth-vs-served on every minute + one probe per trap.
- `tools/unseen-run.sh` — R1–R7 fixed (render portability, comment-aware guard, arg validation,
  UNSEEN_OUT dirname, ADR 0014 at phases 6+7, dense-spine tie count, single verbatim gate with
  SUMMARY assertion).
- `docs/RUNBOOK_UNSEEN.md` — rewritten: three measured rehearsals, R1–R10, A1–A10 statuses, human
  steps incl. `v_dimension_drift` check.

**Open / handed off**
- R9: `content_id = -1` sentinel collision in `cc_hour_agg` is now MEASURED (real −1 session served
  as peak 2, true 1). Schema fix (`is_total` flag or different sentinel) belongs to the hour-agg
  owner — see RUNBOOK R9.
- A3's renamed-pause direction remains unprovable by any self-referential gate; vocabulary probes
  are the only defence and are in the runbook.
- `sql/15_normalise.sql` is not applied by `unseen-run.sh`; the drift check is a documented human
  step (runbook §5.6). Decide whether it should become a phase.

**How to verify** — `tools/unseen-gen.sh`, then the three commands in RUNBOOK §6; gate PASS with
`minutes_compared=1080` and `tools/unseen-verify.sh` exit 0 reproduce this session end to end.
