# doubts/ — the questions only the organisers can answer, with the evidence behind each

> **Summary:** One file per doubt. Each carries the **measured evidence**, the **exact words to ask**,
> **why it is worth mentor time**, and a **decision table** saying what we change for each possible
> answer. The official contract now says judges spot-check results against raw events; older dossier
> Older wording has been updated to the organiser's intended raw-event spot-check semantics. Every
> number is measured against loaded data, never estimated.
> **Record the answer inline the moment it arrives, and update the affected ADR in the same commit.**

## Ask in this order — ranked by measured cost to the answer we submit

Eleven dossiers is more than any mentor will work through. **Ask 09, 04 and 02 first**: they are
worth more than everything below them combined, and each has a decision table so the answer is
immediately actionable.

| # | Doubt | Worth | Blocks |
|---|---|---|---|
| **[09](09-minute-membership-instant-reading.md)** | "Concurrent at minute M" — any overlap, or present at the instant M begins? | **−410 viewers · −14.1%** on the graded peak | the expansion rule in `40_deltas.sql` **and** `90_reconcile.sql` |
| **[04](04-dimension-normalisation.md)** | Hindi is **four** strings — one language or four? | **23.3%** on any per-language answer (1,768 vs 2,180) | which figure a filtered benchmark query submits |
| **[10](10-fail-closed-state-gates.md)** | Must foreground **and** playing both hold, or is a heartbeat enough? | **−10.7% peak · −13.0% hours.** Two independent implementations agree within 2.4%, so this is semantics, not a bug | the state machine in `30_build_intervals.sql` |
| ~~[02](02-resume-semantics.md)~~ | `resume` fires for four different reasons | **PARTLY ANSWERED 2026-08-02** — the irregularity is valid PB-scale data, not a defect, so the "unlogged pause" reading is ruled out. The **9.7%** semantic fork (first vs last resume closes the pause) is still open and still ours. | the pause-exclusion rule |
| [03](03-content-catalog.md) | Empty `video_type`, colliding titles, a poison id | **8.8%** — how content-level answers are labelled | `sql/80_content.sql` views |
| [07](07-tail-credit-at-explicit-stops.md) | Tail credit after an explicit stop | **−4.8% peak · −7.1% hours** (upper edge bounded by 10's terminal-end probe, −4.1%) | `TAIL_S` policy at run ends |
| [08](08-second-truncation-inverts-pause-resume.md) | Second-truncation inverts same-second pause/resume order | **−1.8%** | millisecond precision in the derivation |
| [11](11-liveness-allow-list-unknown-events.md) | Should an **unknown** event grant liveness? | **−1.3% on this file — unbounded on the unseen day**, and no gate would notice | a load-time vocabulary alert |
| [05](05-minute-boundary-membership.md) | An interval ending exactly on a minute boundary | **one viewer** (2,917 vs 2,916) — the narrow half of 09 | minute-membership convention |
| [01](01-heartbeat-cadence.md) | The heartbeat ticks at **40s**, the spec says 60s | every interval boundary, but no single number | `TAIL_S`, `GAP_S` |
| [06](06-dedup-at-filter-grain.md) | Duplicates are inert for totals — and flip 6 dimension attributions | `unk` audio peak 183 vs 184 | whether dedup precedes attribution |

**The costs do not add up.** They overlap (09 subsumes 05; 07's upper edge is bounded by 10) and
several are measured on the same baseline independently. Treat each as *"what this one convention is
worth if we have it backwards"*, not as a total error bar.

**Where they came from.** 01–06 came from reading the data during the build. **07–11 came from
adversarial work on 2026-08-01**: `evidence/adversarial/` probed 21 alternative readings of
conventions the model and gate *share* (ten came back safe at ≤0.1%), and `evidence/liveness/`
measured the exposure that Codex 003 and the design bake-off both raised. Both directories carry the
harness, so any new convention can be measured in one run.

## How these differ from `docs/MENTOR_QUESTIONS.md`

`MENTOR_QUESTIONS.md` ranks all seventeen and carries our current assumption for each, so a mentor can
confirm or deny rather than compose an answer. That file stays authoritative for *what to ask first*.

A `doubts/` file exists where measuring the data **changed the question**. Most of the files below
supersede or sharpen the version in `MENTOR_QUESTIONS.md`:

- **01 supersedes Q17.** Q17 says "your doc claims 1/min, our data is aperiodic." That was wrong — the
  data is not aperiodic, it ticks at 40 s. The sharper question is answerable; the old one invited a
  shrug.
- **02 deepens Q3.** Q3 asks "why are there more resumes than pauses?" and assumes unpaired resumes are
  noise to ignore. They are not noise; they are load-bearing, and the assumption is worth 9.7%.
- **04 is Q18**, and it exists only because measuring created it: ADR 0008 settled the *keys* of the
  four new filter dimensions without examining the *values* in them. It is the one doubt here whose
  machinery is already built either way ([ADR 0011](../docs/adr/0011-normalise-filter-dimensions-at-query-time.md)),
  so the answer changes a `WHERE` clause rather than a model.
- **05 deepens Q8.** Q8 asks "any overlap, or active at the instant?" in the abstract. Measuring found
  the concrete boundary the abstract question hides — an interval ending exactly on a minute boundary
  — and that the two readings differ by **exactly one viewer at the graded peak minute** while both
  the serving SQL and the reconcile gate share one convention, so a green gate cannot decide it.
- **06 scopes `evidence/dedup.txt`.** The dedup-is-inert proof was right at the grain it measured
  (totals) and is wrong at the grain the model now serves (7 dimensions): the attribution vote counts
  events, so duplicates vote. The question — do judges dedup before attributing? — only
  exists because the finer measurement was taken.
- **07, 08, 09 come from the adversarial audit** (`evidence/adversarial/README.md`), which rebuilt the
  interval derivation in a scratch database under **21 alternative readings** of conventions the model
  and the gate share, and measured each against the graded headline. Ten came back safe at ≤0.1%.
  Three moved enough to deserve a mentor: **07** tail credit at explicit stops (−141 peak, −7.1% of
  hours), **08** second-truncation inverting pause/resume order (−52), and **09** minute membership
  read as instant sampling (**−410, −14.1%** — the largest fork we have measured anywhere).
- **09 is the one to ask first, and it partly subsumes 05.** Both deepen Q8. 05 isolates the end
  boundary and is worth one viewer; 09 asks whether membership means any-overlap or
  presence-at-the-instant and is worth 410. A mentor answering 09 probably settles 05 for free; a
  mentor answering only 05 leaves the expensive half open. **09 was filed as `06` by the audit and
  renumbered on merge** — the grain dossier had already taken 06. Nothing else cited it in between.

## Rules for this folder

- **Numbering is append-only.** `01` means the same thing in every commit and worksheet that cites it.
- **Every claim carries the query that produced it.** If you cannot paste the SQL, it does not go in.
- **State our current assumption**, so the mentor confirms or denies instead of composing from scratch.
- **A decision table is mandatory.** If no answer changes what we build, the question is not worth
  mentor time and does not belong here.
