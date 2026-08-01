# doubts/ — the questions only the organisers can answer, with the evidence behind each

> **Summary:** One file per doubt. Each carries the **measured evidence**, the **exact words to ask**,
> **why it is worth mentor time**, and a **decision table** saying what we change for each possible
> answer. These are dossiers, not a list — `docs/MENTOR_QUESTIONS.md` is the ranked list of all 17
> questions and stays the index; a file here exists only where the evidence got deep enough that the
> question changed shape. Every number is measured against the loaded data, never estimated.
> **Record the answer inline the moment it arrives, and update the affected ADR in the same commit.**

## The files

| # | Doubt | Worth | Blocks |
|---|---|---|---|
| [01](01-heartbeat-cadence.md) | The heartbeat ticks at **40s**, the spec says 60s | every interval boundary in the model | `TAIL_S`, `GAP_S` |
| [02](02-resume-semantics.md) | `resume` fires for four different reasons | **189.2 h — 9.7%** of counted watch time | the pause-exclusion rule |
| [03](03-content-catalog.md) | Empty `video_type`, colliding titles, a poison id | how content-level answers are labelled | `sql/80_content.sql` views |

## How these differ from `docs/MENTOR_QUESTIONS.md`

`MENTOR_QUESTIONS.md` ranks all seventeen and carries our current assumption for each, so a mentor can
confirm or deny rather than compose an answer. That file stays authoritative for *what to ask first*.

A `doubts/` file exists where measuring the data **changed the question**. Two of the three below
supersede the version in `MENTOR_QUESTIONS.md`:

- **01 supersedes Q17.** Q17 says "your doc claims 1/min, our data is aperiodic." That was wrong — the
  data is not aperiodic, it ticks at 40 s. The sharper question is answerable; the old one invited a
  shrug.
- **02 deepens Q3.** Q3 asks "why are there more resumes than pauses?" and assumes unpaired resumes are
  noise to ignore. They are not noise; they are load-bearing, and the assumption is worth 9.7%.

## Rules for this folder

- **Numbering is append-only.** `01` means the same thing in every commit and worksheet that cites it.
- **Every claim carries the query that produced it.** If you cannot paste the SQL, it does not go in.
- **State our current assumption**, so the mentor confirms or denies instead of composing from scratch.
- **A decision table is mandatory.** If no answer changes what we build, the question is not worth
  mentor time and does not belong here.
