# Q37 — the contract gate and the real runner disagreed about a valid file

> **Summary:** Two entry points decide whether a file is loadable: the contract gate
> (RUNBOOK §0 — `load.sh` + `validate-source-contract.sh`) and the real runner
> (`tools/unseen-run.sh`). Codex 006 found two valid files the gate passed and the runner
> refused: an RFC-4180 quoted embedded newline, and a new filter column. **Both were the
> runner's fault**, in `tools/unseen-run.sh`, and both are fixed. A third defect found while
> reproducing: the runner's own call to the contract gate could never execute. The invariant
> *anything the gate passes, the runner must accept* is now enforced by
> `tools/contract-runner-agreement.sh`.

## The verdict, per case

| # | case | who was wrong | why |
|---|---|---|---|
| 1 | quoted embedded newline | **the runner** | `wc -l` cannot count RFC-4180 records |
| 2 | new filter column | **the runner** | ADR 0024 supports it; the guard outlived its reason |
| 3 | contract gate never ran | **the runner** | `TARGET` unbound under `set -u` |

Nothing about the contract gate was loosened. Its SQL and its script are unchanged — the
defects were all on the runner's side, and the runner was made to match the loader that
actually does the work.

---

## Case 1 — a quoted embedded newline

RFC-4180 permits a newline inside a quoted field. ClickHouse's `CSVWithNames` reads such a
field as **one** record; `wc -l` sees **two** lines.

`tools/unseen-run.sh` counted data rows as `wc -l` minus one, then asserted
`ev_raw == CSV_ROWS` after the load. On `data/cruel-newline-raw.csv` (98 real records, one of
them carrying `audio_language = "hi\nndi"`):

```
landed: ev_landing 98 rows · content_landing 30 rows
  ev_raw       landed 98 = typed 98 + rejected 0        <- a PERFECT load

=== FAILED: 2 load (tools/load.sh, unmodified) ===
ev_raw holds 98 rows, the CSV has 99 data rows.
A partial or doubled load is worse than no load [...]
```

The loader was right, the ledger identity held, every row typed cleanly — and the harness
killed the run on its own arithmetic. `evidence/q37/before/runner-newline.txt`.

Meanwhile the contract gate, run against the very database that load produced, returned
**`VERDICT: WARN — 0 failures`**, exit 0 — a pass. `evidence/q37/before/gate-newline.txt`.

**Fix.** Count records with a real CSV parser (`python3 csv.reader`, the same module
`load.sh`'s `analyse_header()` already uses), not with `wc -l`.

**What it costs**, measured on the real 233 MB / 905,558-row file:

| | answer | wall clock |
|---|---:|---:|
| `wc -l` minus 1 | 905,558 | 0.21 s |
| `csv.reader` records | 905,558 | 1.19 s |

The two agree on the provided file — it happens to contain no embedded newline — so the fix
buys correctness on the files where they *differ* for about **one second** on the largest
input we have. The phase-0 timings in `docs/RUNBOOK_UNSEEN.md` are being re-measured
separately (Q38) and were deliberately left untouched here; this is the delta that work
should absorb.

## Case 2 — a new filter column

`dataset_details.md:43` says in writing that the solution should keep working as dimensions
increase, and ADR 0024 exists to carry unknown columns. The loader implements it: a 14th
column `experiment_id` is announced and carried into the `extra` Map.

Measured on `data/cruel-newcol-raw.csv` through the gate path:

```
header shape: ev_raw <- data/cruel-newcol-raw.csv
  NEW columns (1): experiment_id
    -> carried into the `extra` Map — queryable today as extra['experiment_id']
  ev_raw       landed 128 = typed 128 + rejected 0

SELECT extra, count() FROM ev_raw GROUP BY extra
  {'experiment_id':'exp42'}   128
```

Every row kept it. The gate then passed: `VERDICT: WARN — 0 failures`, exit 0.

The runner refused the same file at preflight, comparing the header against a fixed
13-column string:

```
=== FAILED: preflight ===
raw CSV header does not match what tools/load.sh inserts.
Columns are mapped by POSITION, not by name. Fix the loader before continuing.
```

That last sentence is the tell. **It stopped being true when ADR 0024 landed.**
`analyse_header()` builds its `input()` structure from the actual header and maps
`exprs = [c if c in header else missing_land(c) for c in known]` — by name. The loader even
prints `REORDERED (safe — columns map by name)`. The guard outlived the fact that justified
it, and its error message was still instructing the operator to "fix the loader" for doing
the thing the ADR asked it to do.

**Fix.** The preflight is now a **strict subset** of `analyse_header()`'s refusal rules. It
stops only on what no flag can rescue — a missing `event_timestamp` or `video_session_id`,
duplicate header columns, a new column name that is not a plain identifier, an empty file.
Everything subtler is *announced* and left to the loader, which runs a few lines later and is
the authority. A preflight quieter than the loader is safe; a preflight stricter than the
loader is the defect this replaced.

## Case 3 — found while reproducing: the gate could not run inside the runner

Phase 2b wires the contract gate into the runner. It selected its target with:

```bash
CONTRACT_ARGS=""
[ "$TARGET" = cloud ] && CONTRACT_ARGS="-c"
```

`TARGET` is not set by `.env` and is not exported anywhere in `unseen-run.sh`. Under
`set -euo pipefail`:

```
TARGET unset : t.sh: line 4: TARGET: unbound variable
TARGET=local : SURVIVED, C=
TARGET=cloud : SURVIVED, C=-c
```

Unset aborts the run outright; and `TARGET=local` survives only because the `&&` list is the
whole statement — set it to anything that is not `cloud` and `set -e` kills the run too. Only
`TARGET=cloud`, exported by the caller, ever got through.

Phase 2b was added after Codex audit 005 found that the gate "existed on paper and not on the
path". It was then put on the path — and still could not execute. Every connection this
script makes is Cloud, so the fix is `CONTRACT_ARGS="-c"`, unconditionally.

This is why the after-evidence is the first run in which `source contract: no FAIL` appears.

---

## After

Both files now run end to end, reconcile gate green:

| fixture | runner exit | records | reconcile |
|---|---|---|---|
| `cruel-newline-raw.csv` | 0 | 98 = 98 | GATE PASSED, peak 4 @ 2026-08-22 09:00 |
| `cruel-newcol-raw.csv` | 0 | 128 = 128 | GATE PASSED, peak 4 @ 2026-08-22 09:00 |

`evidence/q37/after/runner-newline.txt`, `evidence/q37/after/runner-newcol.txt`.

### The guard still guards

The brief's warning — *do not silently loosen the gate to make them agree* — is the reason
`evidence/q37/after/negative-shape.txt` exists. Every one of these is still refused, by name:

```
nots     exit=1  REFUSING: missing columns no flag overrides: event_timestamp
nosid    exit=1  REFUSING: missing columns no flag overrides: video_session_id
dupe     exit=1  REFUSING: duplicate header columns: country
badname  exit=1  REFUSING: new column names that are not plain identifiers: 'a-b c'
empty    exit=1  REFUSING: the raw CSV is empty — no header row
misscol  exit=1  (announced at preflight, refused by load.sh at phase 2)
```

`misscol` is the interesting one: the runner *announces* the missing `country` column and
defers, and `tools/load.sh` then refuses it with the precise message and the fix —
`--allow-missing country`. One authority, one message, no duplicated rule to drift.

## The regression

`tools/contract-runner-agreement.sh` feeds the same file to both entry points and asserts
they agree. Output: `evidence/q37/agreement.txt`.

Only one direction fails it: **gate ACCEPT + runner REFUSE-FILE**. Both-accept and
both-refuse pass; gate-refuse + runner-accept passes too, because the gate is allowed to be
the stricter of the two — stopping early costs only time.

It classifies runner failures by the phase named in the runner's own banner, so a reconcile
failure is reported as `RAN-BUT-FAILED` rather than counted as a file-acceptance violation.
And it carries two **both-refuse controls** (`ctl-misscol`, `ctl-dupecol`) whose job is to
fail if agreement is ever achieved by a guard that stopped guarding. If those rows ever read
`ACCEPT/ACCEPT`, the script has stopped testing anything.

It runs the real `unseen-run.sh`, not a short-circuit mode of it — a "just check the shape"
mode would be one more place for the two paths to drift apart.

**Case 3's trap is not a one-off.** The first run of this very script died silently on its
first both-refuse fixture, with no verdict printed, on `[ "$rc" -eq 0 ] && { echo ACCEPT;
return; }` — a trailing `&&` list evaluating false, returning 1 for the whole statement,
inside `$( )`, under `set -e`. Identical shape to the line that stopped phase 2b from ever
running the contract gate. Both are now `if`/`fi`. In a repo whose scripts all run
`set -euo pipefail`, `cond && action` as a statement's last form is a live hazard, not a
style preference.

---

## Found here, left for a follow-up: a load refusal is missing from the evidence file

When `tools/load.sh` refuses a file, `tools/unseen-run.sh` produces **no `=== FAILED: ===`
banner**, and the loader's `REFUSING:` lines **do not reach `UNSEEN_OUT`**. Two causes, both
in phase 2:

```bash
( cd "$SANDBOX" && ... "$REPO/tools/load.sh" ... ) | tee -a "$OUT"
```

1. Only **stdout** is teed. The loader writes its refusal and its `=== load.sh FAILED ===`
   marker to **stderr**, which goes to the operator's terminal and nowhere else.
2. `set -o pipefail` makes the failing pipeline non-zero, so `set -e` kills the script
   *before* `die()` runs — the phase banner the file's own header promises ("A failing phase
   prints a banner naming the phase and stops") never prints.

The run still fails loudly and correctly on the terminal, so this is a legibility and
evidence-retention defect rather than a correctness one: the committed
`evidence/unseen-rehearsal.txt` for a refused load ends mid-phase with no stated reason.

Not fixed here because it is a change to phase 2's error handling rather than to what either
entry point considers a valid file, and `docs/RUNBOOK_UNSEEN.md`'s phase table is being
edited concurrently (Q38). `tools/contract-runner-agreement.sh` works around it by capturing
the runner's stderr separately and reading the loader's own markers — see `runner_verdict()`,
which would otherwise report a plain file refusal as `RAN-BUT-FAILED` and could go quiet on
the very drift it exists to catch.

## Left deliberately inconsistent, with the reason

**The sentinel audit.** A file carrying `content_id = -1` or `platform = '*'` gets `WARN`
from the contract gate (exit 0 — a pass) and is **refused** by the runner unless
`UNSEEN_ACK_SENTINEL=1` is typed. That is technically the same asymmetry, and it is being
kept:

- it is a deliberate stop-and-think with a documented one-flag override, not a rule that
  drifted out of sync;
- the gate `WARN`s on exactly the same condition, so the operator is told twice rather than
  surprised once;
- ADR 0022 makes the cube structurally safe, but the `p_* = -1` query API in
  `sql/85_windows.sql` stays genuinely ambiguous for a real `content_id = -1`, so a hard stop
  is the right default.

The same reasoning covers `UNSEEN_ACK_CONTRACT=1`, which lets the operator proceed past a
gate `FAIL`. Both are acknowledgement paths, not disagreements about what a valid file is.

## Not fixed here — outside this worktree's ownership

`tools/cruel-gen.sh` (not owned by Q37) now carries three stale claims, all of which
*understate* the pipeline:

1. Its `list` output says `newcol … designed; loader silently drops (measured)`. The loader
   neither drops nor is silent — it announces the column and carries it into `extra`
   (128/128 rows, measured above). The claim predates ADR 0024.
2. Its `run_one` branch for `newcol`/`misscol` prints *"harness ACCEPTED a newcol file — its
   header guard has regressed"* when the runner exits 0. After this fix the runner exits 0
   for `newcol` **by design**, so that message is now backwards for that knob. `misscol` is
   unaffected — it still exits non-zero.
3. Its `newline` knob is registered as expected-to-die (`badtypes|newline` branch) with
   `expect_broken` text naming the `wc -l` assert. That death no longer happens; the knob
   will now print *"ran CLEAN — that is itself a finding"*, which is correct in spirit but
   reads as a surprise rather than the fixed outcome.

Separately, the `badtypes` knob's expected death is likely stale for a different reason —
ADR 0030's all-String landing table means a malformed value now costs a row, not the file.
Not verified here; flagged for whoever owns `cruel-gen.sh`.
