# evidence/source-contract — the gate's known-good baseline and its firing proof

> **Summary:** Two transcripts of `tools/validate-source-contract.sh` (ADR 0026, read-only).
> `baseline-sonyliv-2026-08-02.txt` is the graded file's verdict — 0 FAIL, 3 explained WARNs —
> and the reference the unseen day is diffed against. `selftest-hostile-2026-08-02.txt` proves
> every probe actually fires: a scratch DB fed one designed violation per probe FAILed both
> phases (missing column; 17 hostile rows), exit 1. A gate never seen firing is untested.
> Reproduce: `tools/validate-source-contract.sh -c` (baseline) / commands in the selftest header.

## How to read the baseline on the unseen day

Run the gate on the freshly loaded day, put the two outputs side by side, and ask three
questions, in order:

1. **Any FAIL row non-zero?** Stop. The file is not the protocol we modeled — wrong units,
   wrong shape, empty identity, or a new `event_type`. Nothing downstream is trustworthy.
2. **Any WARN row that is zero here but non-zero there?** That is new behaviour, not noise.
   The one that matters most is **vocabulary drift**: unknown events FAIL OPEN in the model —
   they extend activity silently, and no other gate can see it (doubts/11).
3. **Any WARN count that moved by more than the volume ratio explains?** 4,209 retry copies
   on 905,558 rows is ~0.5%; if the new day shows 5%, retries changed character.

The three baseline WARNs and why they are known-good:

| WARN | count | why it stays |
|---|---:|---|
| columns beyond the 13-column contract | 1 | `ingested_at` — DDL drift on `sonyliv` only, ALTERed 2026-08-01 19:16:50 by the rejected research branch's tooling (ADR 0026). A scratch DB built from `sql/00_schema.sql` will not show it. |
| multiple VideoSessionEnd in one session | 14 | the end marker is an idempotent hard stop in the model |
| exact duplicate rows (retry copies) | 4,209 | dedup proven inert for totals/peak, open at filter grain (doubts/06) |
