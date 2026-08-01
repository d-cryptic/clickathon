# Explicit-state audit — what ignoring 29,021 AppBackgrounded/AppForegrounded events actually costs

> **Summary:** The spec names background/foreground markers; our model ignores all 29,021 of them and
> infers backgrounding from heartbeat gaps (ADR 0007). This audit priced that choice: of **916.3 h**
> the events explicitly mark as backgrounded, the shipped model already excludes **96.8%** — only
> **29.3 h** is still counted as watching — because **75.4% of backgrounds are preceded (≤10 s) by an
> explicit `pause`** our pause windows already cut. Using the events directly moves the headline at
> most **−74 peak (−2.5%)** across three constructions (literal transitions −45, conservative union
> −74, explicit-only-no-gaps −65); the single largest component is the **60 s
> tail credited after an explicit background (−37)**, not the windows (−8). Unmatched pairs recounted:
> **337** bg never see an fg (ADR 0007's "379" was the global count difference), and the choice of
> unclosed rule is worth **≤3 viewers**. ADR 0007 is vindicated with a number; the tail corner is not.

**Measured:** 2026-08-02 · local ClickHouse 26.7.1 · `default.ev_raw`, 905,558 rows (same count as
graded `sonyliv.ev_raw`, reads only — the graded DB was never written) · scratch DB `exs_q12` ·
baseline rebuilt from `sql/30_build_intervals.sql` verbatim and reproducing the graded numbers
exactly: **30,323 intervals · 1,978.1 h · peak 2,917 @ 2026-07-26 10:56**. Raw outputs in
[out/](out/); dossier: [doubts/12](../../doubts/12-explicit-background-events.md).

---

## Why this audit exists

`docs/upstream/dataset_details.md` enumerates `AppBackgrounded`/`AppForegrounded`;
`docs/upstream/PROBLEM_STATEMENT.md` names *"background/foreground events"* as a way to cut inactive
segments. We use neither: `sql/30_build_intervals.sql` and `sql/90_reconcile.sql` contain zero
references to either event (verified), and the graded DB carries 14,700 + 14,321 = 29,021 of them.
[ADR 0007](../../docs/adr/0007-gate-answers-pause-needs-explicit-handling.md) defended the choice
(events "not guaranteed", pairs unmatched, gaps measurable) and two reviewers flagged it (Codex 003
§7.2.2; `docs/design-bakeoff.md`) — but nobody had measured the alternative. Now it is measured.

## Method

The [adversarial harness](../adversarial/README.md) pattern, unchanged: `gen_variants.py` patches
the *shipped* `sql/30_build_intervals.sql` byte-for-byte except the stated change (anchored string
replacement — a failed anchor raises, so drift in the shipped file cannot silently produce a stale
variant), each variant lands in its own `exs_q12.si_<variant>` MergeTree, and headline metrics use
the gate's own expansion semantics (`90_reconcile.sql` `truth_min`: inclusive minute range,
`uniqExact(video_session_id)`). `run.sh` builds and measures; `analysis.sql` holds the query-only
probes. **Baseline reproduced the graded 30,323 / 1,978.1 h / 2,917 @ 10:56 exactly before any
variant was trusted.**

## The five measurements

| # | Variant | Rule | Intervals | Hours | Δh | Peak | Δpeak | Peak minute |
|---|---|---|---|---|---|---|---|---|
| — | `baseline` | shipped: gaps + pause windows, bg/fg ignored | 30,323 | 1,978.1 | — | **2,917** | — | 10:56 |
| 1 | `v1_transitions` | **literal**: bg closes immediately → next fg reopens; unclosed → run end; bg state carried across runs; tail capped at next bg | 31,019 | 1,945.8 | −32.3 (−1.6%) | 2,872 | **−45 (−1.5%)** | 10:56 |
| 1a | `v1_shipped_tail` | v1 minus the tail cap — isolates windows from tail | 31,019 | 1,967.8 | −10.3 (−0.5%) | 2,909 | **−8 (−0.3%)** | 10:56 |
| 2 | `v2_union` | **both signals, whichever first**: bg/fg no longer renew liveness (a bg-bridged silence is a gap again) + v1 windows + capped tail | 30,218 | 1,935.9 | −42.2 (−2.1%) | 2,843 | **−74 (−2.5%)** | 10:56 |
| 3 | `v3_explicit_only` | **gaps ignored**: one run per session; only pause + bg/fg windows cut the span | 29,931 | 1,946.2 | −31.9 (−1.6%) | 2,852 | **−65 (−2.2%)** | 10:56 |
| 5a | `v5a_to_run_end` | v1 windows, unclosed bg → run end, **no** cross-run carry | 31,030 | 1,946.4 | −31.7 | 2,873 | −44 | 10:56 |
| 5b | `v5b_next_event` | unclosed bg → next event (blip reading) | 31,039 | 1,947.1 | −31.0 | 2,875 | −42 | 10:56 |
| 5c | `v5c_next_heartbeat` | unclosed bg → next `VideoHeartbeat` | 31,038 | 1,947.0 | −31.1 | 2,875 | −42 | 10:56 |

**No variant moved the peak minute off 2026-07-26 10:56** — consistent with the adversarial ledger:
the peak's location is convention-proof on this file, only its value moves.

### 4 · Agreement analysis — the number that decides the question

For every `AppBackgrounded`, build the explicit window (bg → next fg; unclosed → last session
event) and intersect with the baseline's active intervals:

```
 explicitly-marked background time            916.3 h   (13,824 non-zero windows)
 of which the baseline counts as watching      29.3 h   =  3.2%
 already excluded by gaps + pause windows     887.0 h   = 96.8%
```

Why the overlap is so small even though 60% of bg events see another event within 60 s (so a gap
alone would *not* fire): **the explicit signals are redundant with signals we already use.**

- **11,086 of 14,700 bg events (75.4%) have an explicit `pause` ≤ 10 s before them** (12,604 = 85.7%
  within 60 s) — the OS pauses playback on backgrounding, the pause window opens, and the trailing
  telemetry chatter after the bg is already inside an excluded window.
- 3,419 bg events (23%) are followed by ≥150 s of total silence (the gap fires exactly at the bg);
  4,229 (29%) see a >150 s gap start within 150 s.
- The residue — 29.3 h over the file's 11.8-day span, 1.5% of the 1,978.1 h counted — is all the
  explicit events know that gaps + pauses do not.

So the two signal families catch **the same population**, not different ones: backgrounding almost
always announces itself as a pause first, and heartbeats then stop (ADR 0007 GATE ①: 0.047/min
while backgrounded). This is the measured vindication ADR 0007 lacked.

### 5 · The unmatched pairs, recounted

| | |
|---|---|
| `AppBackgrounded` with no `AppForegrounded` at-or-after it (same session) | **337** (2.3% of 14,700) |
| ADR 0007's cited figure | 379 — that is the *global* count difference 14,700 − 14,321; the per-session truth is 337 |
| orphan `AppForegrounded` with no prior bg | 29 |
| sessions carrying ≥1 bg event | **10,866 of 10,866 — every session** |
| bg that is the last event of its session | 231 |

Cost of each plausible unclosed rule (v5a/b/c above): **the whole spread is 3 viewers of peak and
1.3 h** (2,872…2,875 / 1,945.8…1,947.1). Carrying bg state across runs (v1 vs v5a) is worth −1 peak
/ −0.6 h. ADR 0007's "pairs are unmatched" concern is real but priced at noise level: 337 events,
whose worst-case handling difference is 0.1% of the headline.

## Ranking — how much each reading moves the answer

| Rank | Reading | Peak move |
|---|---|---|
| 1 | Conservative union of both signals (`v2_union`) | **−74 · −2.5%** |
| 2 | Explicit events only, gaps ignored (`v3_explicit_only`) | −65 · −2.2% |
| 3 | Literal transitions on top of the shipped model (`v1_transitions`) | −45 · −1.5% |
| 3a | └ of which: 60 s tail credited after an explicit bg (tail cap alone) | **−37** |
| 3b | └ of which: the bg→fg windows themselves (`v1_shipped_tail`) | −8 · −0.3% |
| 4 | Unclosed-pair rule choice (run end vs next event vs next heartbeat) | ≤3 |
| 5 | Carrying bg state across gap-split runs | −1 |

The decomposition is the story: **the windows are nearly free (−8) because gaps + pauses already
exclude that time; over half of every variant's delta is the tail rule** — 2,392 runs end at an
`AppBackgrounded` ([doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md) §2) and each
collects 60 s of grace *after the viewer demonstrably left*; capping the tail at the next bg is
−37 peak / −22.0 h on its own. That corner belongs to the tail-credit question
([doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md) measured the sibling rule — no tail
at explicit `VideoSessionEnd`/`pause` — at −141 peak) and is actionable without any mentor ruling
on bg/fg semantics.

## A worked example (the residue, in one session)

Session `EA0B43…8887` (events: pause/resume pairs, then bg 11:07:08 → fg 11:09:25 → bg 11:09:31 →
fg 11:11:15 → end 11:11:20; heartbeats kept flowing throughout — no gap ever fired):

```
 baseline    …  11:06:54 → 11:12:20          (both backgrounds counted as watching)
 v1          …  11:06:54 → 11:07:08 (bg)     |  11:09:25 (fg) → 11:09:31 (bg)  |  11:11:15 (fg) → 11:12:20
```

The variant closes at each `AppBackgrounded` and reopens at each `AppForegrounded`, exactly as
specified — this session's ~4 backgrounded minutes are part of the 29.3 h residue where telemetry
chatter kept the lease alive. Sessions like it are the entire measured cost of ADR 0007.

## Relationship to doubts/07, /10, /11

- **[doubts/10](../../doubts/10-fail-closed-state-gates.md)** (fail-closed gates, −311 peak): this
  audit *decomposes* it. Explicit bg/fg used as transitions accounts for only −8…−45 of the −311;
  the rest is the playing gate, the liveness allow-list, terminal ends and tail rules. The big fork
  in doubts/10 is **not** about the background markers — it is about play-state and liveness. (Our
  `v1_shipped_tail` 2,909 sits just above doubts/10's fg-gate-only upper bound 2,905 because there
  bg/fg also stopped renewing liveness; that difference is measured here as `v2_union`'s extra step.)
- **[doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md)** (allow-list, −37): its
  "runs ending at a bg earn tail into known-background time" corner (≈39.9 h raw) is priced here
  net of overlaps: −37 peak / −22.0 h (rank 3a).
- **[doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md)** (tail at explicit stops, −141):
  the bg-capped tail is the same rule with a third stop event; the two caps partially overlap
  (a run can end at a pause *and* have a bg 2 s later).

## Reproduction

```bash
python3 evidence/explicit-state/gen_variants.py   # regenerate sql/ from the shipped derivation
evidence/explicit-state/run.sh                    # build all variants in exs_q12 + print metrics
# query-only probes (agreement, unmatched):
#   statements in analysis.sql, outputs in out/agreement.txt
```

`out/variants.txt` and `out/meta.txt` carry the captured run. Baseline must print
`30323 · 1978.1 · 2917 · 2026-07-26 10:56:00` before any delta is trusted.
Cleanup when no longer re-derived: `tools/ch "DROP DATABASE exs_q12"`.

## Housekeeping for owners of neighbouring files (not touched, per ownership rules)

- `doubts/README.md` index needs a row for 12 (doubts-index owner).
- ADR 0007's "379 unmatched" figure is the global count difference; the per-session count is 337
  (ADR owner may want the footnote).
- The bg-capped tail (−37 peak) is actionable inside doubts/07's tail ruling without any bg/fg
  semantics change — worth folding into that dossier's decision table when it gets an answer.
