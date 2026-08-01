# Liveness exposure audit — how much of the answer exists only because liveness is granted broadly

> **Summary:** Codex 003 §7.2.1/3/9 and the design bake-off both say our model grants liveness too
> broadly: every event renews a run, `VideoSessionEnd` is not terminal, unknown events fail open. This
> audit measured each exposure against the graded headline (peak **2,917** · **1,978.1 h**) in scratch
> `liv_q28`. Ranking: **fail-closed composite −311 peak / −10.7%** ([doubts/10](../../doubts/10-fail-closed-state-gates.md));
> **terminal `VideoSessionEnd` −119 / −4.1%** (already dossier'd as [doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md));
> **allow-list liveness only −37 / −1.3%** ([doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md) —
> small today, **unbounded on the unseen day**, hence the allow-list gate proposal). The full event
> vocabulary (47 pairs) is committed here as [vocabulary.tsv](vocabulary.tsv) — it was written down nowhere else.

**Measured:** 2026-08-01/02 · local ClickHouse, scratch DB `liv_q28` (graded `sonyliv` never written).
Baseline rebuilt verbatim from `sql/30_build_intervals.sql` via the harness pattern of
[evidence/adversarial/README.md](../adversarial/README.md) and reproduced the graded numbers exactly
— **30,323 intervals · 1,978.1 h · peak 2,917 @ 2026-07-26 10:56** — before any probe was trusted.
Headline metrics use the gate's own expansion semantics (inclusive minute range,
`uniqExact(video_session_id)`).

---

## Q3 · The event vocabulary (measured first, because the allow-list starts here)

[vocabulary.tsv](vocabulary.tsv) — every distinct `(event_type, event)` pair with event and session
counts. **47 pairs: 7 event_types, of which `VideoHeartbeat` fans out into 41 sub-events.** Nothing in
the repo had enumerated this before; the model's semantics reference exactly three values
(`pause`, `resume`, `VideoSessionEnd`) and treat the other 44 as anonymous timestamps.

Top of the distribution (of 905,558 events):

```
 VideoHeartbeat / network-activity   177,485   19.6%      ┐ the three 40 s metronomes
 VideoHeartbeat / buffer-health      167,460   18.5%      │ (DATA_DICTIONARY trap 6)
 VideoHeartbeat / video-resize       141,250   15.6%      ┘
 VideoHeartbeat / BufferStart+End    132,930   14.7%
 VideoHeartbeat / video_forward,Seek  81,915    9.0%
 VideoHeartbeat / resume+pause        59,120    6.5%   ← the only two with modeled semantics
 AppBackgrounded / AppForegrounded    29,021    3.2%   ← liveness-granting today; see Q1
 VideoPlay / VideoSessionStart/End    32,644    3.6%
 VideoError                              293    0.03%
 …plus 32 long-tail sub-events (upshift, downloads, ads, chromecast, …)
```

## Q1 · Active time that exists only because a non-heartbeat event bridged a gap

Three rebuilds, each a **single-line change** to the `ts` aggregation (the run-splitting array);
pause/resume/end semantics untouched:

| Variant (what still grants liveness) | Intervals | Hours | Peak | Δ peak |
|---|---:|---:|---:|---:|
| baseline — every event (shipped) | 30,323 | 1,978.1 | **2,917** | — |
| all except `AppBackgrounded`/`AppForegrounded` | 29,662 | 1,987.1 | 2,905 | **−12 · −0.4%** |
| …also except `VideoError` | 29,659 | 1,987.0 | 2,905 | −12 · −0.4% |
| allow-list: `VideoHeartbeat` + `VideoPlay` only | 29,343 | 1,961.5 | 2,880 | **−37 · −1.3%** |

Supporting counts: of 3,925 gaps > 150 s between consecutive *allowed* events, only **147 are truly
bridged** in the shipped model (every sub-gap ≤ 150 s via excluded events), worth **7.1 h**. The
events doing the bridging are almost entirely bg/fg (2,554 `AppForegrounded` + 2,516
`AppBackgrounded` inside such gaps; `VideoError` appears twice).

Hours *rise* +9.0 h when bg/fg stop granting liveness — the same interaction as adversarial ledger
row 6: shorter runs give conservative unclosed pauses less run to eat, and every extra split mints a
60 s tail. The peak still falls, because bridged gaps at the peak minute stop counting.

**Verdict: the criticism is theoretically right and practically small on this file — ≤1.3% of the
peak.** The live risk is not the measured delta; it is that the mechanism is *unbounded* for event
values we have not seen (doubts/11).

The perverse corner, measured: classifying the event at each run's end, **2,392 of 14,954 runs
(16%) end at an `AppBackgrounded` with no heartbeat in the same second** — each collects 60 s of
tail credit *after the viewer demonstrably backgrounded* (≈ 39.9 h of tail into known-background
time). 2,427 end at bg/fg combined; 10,758 end at `VideoSessionEnd` (doubts/07's territory).

## Q2 · Credit after an explicit `VideoSessionEnd`

- **108 of 10,866 sessions (0.99%)** have events after their last end event — 667 events, lag
  p50 **444 s** / p90 1,320 s / p99 1,841 s / max 2,081 s. 14 sessions carry multiple end events.
- Active time booked after the last end event: **128.1 h (6.5% of all hours)** — of which
  **124.2 h is the 60 s tail paid at the end event itself** (doubts/07's `no tail after
  VideoSessionEnd` variant: 1,853.9 h, −113 peak) and **1.63 h is 36 whole intervals** formed
  by post-end events (adversarial row 14).
- **End-is-terminal rebuild** (clip every interval at the session's first end, drop later ones):
  **30,265 intervals · 1,849.8 h · peak 2,798 (−119 · −4.1%)** — doubts/07's −113 plus −6 from
  post-end intervals and run remainders.

No new dossier: [doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md) already carries this
question with mentor wording; the terminal-clip variant here just bounds its upper edge at −119.

## Q4 · The fail-closed reading, on our implementation

The bake-off reports the challenger (state-gated, fail-closed) at **1,762.4 h, ~11% below us** — on
*its* code, so nothing separated semantics from implementation. This rebuild applies the fail-closed
rules inside **our own derivation** ([fail-closed-variant.sql](fail-closed-variant.sql)): liveness
from `VideoHeartbeat`/`VideoPlay` only; a playing gate (open at play/resume, closed at pause/end,
run time before the first play excluded); a foreground gate (closed at `AppBackgrounded`, reopened
at `AppForegrounded`, unclosed → run end, state carried across runs); `VideoSessionEnd` terminal for
its run; tail only into silence and capped at the next explicit stop.

| Variant | Intervals | Hours | Δ hours | Peak | Δ peak |
|---|---:|---:|---:|---:|---:|
| baseline (shipped, lease semantics) | 30,323 | 1,978.1 | — | 2,917 | — |
| fail-closed, all gates | 27,818 | **1,720.3** | **−13.0%** | **2,606** | **−311 · −10.7%** |
| fail-closed minus the foreground gate | 29,078 | 1,791.2 | −9.4% | 2,704 | −213 · −7.3% |

Our fail-closed reading lands at **1,720.3 h vs the challenger's 1,762.4 h** — within 2.4% of each
other from two independent implementations, against 1,978.1 h shipped. The **two implementations
agreeing with each other while disagreeing with the incumbent by ~11–13%** is the strongest form of
this evidence: the gap is the *semantics*, not either codebase. Decomposition: the foreground gate
alone is worth −98 peak / −70.9 h inside the composite; the play-gate + terminal-end + allow-list
carry the rest. Dossier: [doubts/10](../../doubts/10-fail-closed-state-gates.md).

## Ranking — what moves the answer, largest first

| # | Exposure | Peak Δ | Hours Δ | Dossier |
|---|---|---:|---:|---|
| 1 | Fail-closed state-gated reading (composite) | **−311 · −10.7%** | −257.8 h · −13.0% | **[doubts/10](../../doubts/10-fail-closed-state-gates.md)** (new) |
| 2 | `VideoSessionEnd` terminal (tail + post-end) | −119 · −4.1% | −128.3 h · −6.5% | [doubts/07](../../doubts/07-tail-credit-at-explicit-stops.md) (existing; upper edge added) |
| 3 | Liveness allow-list (bg/fg/error/telemetry stop renewing) | −37 · −1.3% | −16.6 h · −0.8% | **[doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md)** (new — the unseen-day risk) |
| 4 | Whole intervals formed after the last end event | ~0 | −1.63 h · −0.08% | subsumed by 2 |

Every variant peaks at the same minute, 2026-07-26 10:56 — consistent with the adversarial audit:
conventions move the peak's value, never its location, on this file.

## The proposed defence (not implemented): a liveness allow-list that alerts

**What:** commit [vocabulary.tsv](vocabulary.tsv) as the known-event contract. At load time (both
`tools/load.sh` and the unseen-day path in `tools/unseen-run.sh`), one query compares the incoming
file's distinct `(event_type, event)` pairs against it and **fails the load** (`throwIf`) on any
pair not present — surfacing new vocabulary for a human semantic ruling instead of silently letting
it extend activity. This is the same shape as the challenger's source-contract gate the bake-off
already recommends cherry-picking (its recommendation 2a); this adds the concrete contract file.

**What it deliberately does not do:** change the model. `sql/30_build_intervals.sql` keeps granting
liveness by timestamp; the gate only guarantees no *unreviewed* event value ever reaches it. If a
mentor ruling on doubts/11 later restricts liveness to the allow-listed values, the same TSV becomes
the model's `IN` list — one file, two uses.

**Cost:** one committed 48-line TSV + one guard query (sub-second on 905k rows; it is a
`GROUP BY` over two LowCardinality columns) + ~15 lines of shell. No schema change, no rebuild,
no new tool. **Where:** the guard query belongs beside the existing row-count/checksum checks in
`tools/load.sh`, and in `tools/unseen-verify.sh` for the unseen day (owners: those files' owners —
this audit proposes, per its brief, and does not implement).

## Reproduction

```bash
# scratch DB pattern, graded DB never written; harness identical to evidence/adversarial/README.md
V=baseline  # then: nobgfg | nobgfgerr | allowhb | failclosed
tools/ch "CREATE DATABASE IF NOT EXISTS liv_q28"
tools/ch "CREATE TABLE liv_q28.si_${V} (…13 cols as sql/10_intervals.sql…) ENGINE=MergeTree ORDER BY (video_session_id, interval_start)"
sed -e "s/INSERT INTO session_intervals/INSERT INTO liv_q28.si_${V}/" \
    -e "s/FROM ev_raw/FROM default.ev_raw/" <variant.sql> | tools/ch "$(cat)"
```

Variant recipes:

- **Q1** one-line edit to the `ts` line of `sql/30_build_intervals.sql`:
  `groupArray(toUnixTimestamp(event_timestamp))` → `groupArrayIf(toUnixTimestamp(event_timestamp),
  event_type IN ('VideoHeartbeat','VideoPlay'))` (or `NOT IN ('AppBackgrounded','AppForegrounded')`).
- **Q2** query-only over `liv_q28.si_baseline`: join `minIf/maxIf(ts, event_type='VideoSessionEnd')`
  per session, clip `least(interval_end, first_end)`, drop intervals starting at/after it.
- **Q4** [fail-closed-variant.sql](fail-closed-variant.sql), committed here verbatim.

Cleanup: `DROP DATABASE liv_q28` once the numbers stop being re-derived.
