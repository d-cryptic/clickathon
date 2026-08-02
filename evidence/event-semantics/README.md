# Event-semantics contract — what the fail-closed default costs, and what it buys

> **Summary:** ADR 0033 replaces "every event renews liveness, unknown ones included" with a declared
> 47-pair contract ([contracts/event_semantics.tsv](../../contracts/event_semantics.tsv)) whose default
> for an UNDECLARED pair is **grant nothing**. Measured cost on the delivered file: **ZERO** — 30,323
> intervals · 1,978.1 h · **PEAK 2,917 @ 2026-07-26 10:56**, interval boundaries **bit-identical** to
> the pre-0033 build (0 rows differ), gate green over 17,028 minutes. Measured value: an undeclared
> `AppKeepalive/tick` — a plausible client event — takes the fail-open peak to **5,004 (+71.5%)** and
> **moves the peak minute**; under the contract the same file yields 2,917 @ 10:56, unchanged. Measured
> risk of the mechanism: one wrongly-omitted pair is worth between **−131 and +18** peak.

**Measured:** 2026-08-02 · local ClickHouse, scratch DB `evsem_q33` (graded `sonyliv` never written,
never read for this) · branch `feat/event-semantics-contract`. Every variant is a **full rebuild** of
`sql/30_build_intervals.sql` with only the contract expressions changed, into its own table. Headline
metrics use the gate's expansion semantics (inclusive minute range, `uniqExact(video_session_id)`).
Baseline was rebuilt first from the **pre-edit** file and reproduced the graded headline exactly
before any probe was trusted.

---

## 0 · Baseline, and the no-op proof

| build | intervals | hours | PEAK | minute |
|---|---:|---:|---:|---|
| pre-0033 `sql/30_build_intervals.sql`, verbatim | 30,323 | 1,978.1 | **2,917** | 2026-07-26 10:56 |
| post-0033, contract at the shipped policy | 30,323 | 1,978.1 | **2,917** | 2026-07-26 10:56 |

Not merely equal in aggregate. Compared row by row on all twelve non-`build_version` columns:

```
rows only in pre-0033 build   0
rows only in post-0033 build  0
```

And end to end: `sql/90_reconcile.sql` (now contract-driven) against the serving layer that the
**pre-contract** model built —

```
0  SUMMARY  minutes_compared=17028  mismatched=0  max_abs_diff=0  peak=2917  PASS
```

Full run, all four sections, captured verbatim in
[`reconcile-local.txt`](reconcile-local.txt) (`tools/reconcile.sh`, target local, exit 0). The
committed `evidence/reconcile.txt` is a **Cloud** run and was deliberately left untouched — a local
run is not an upgrade on it.

**Nothing we would submit moves.**

## 1 · The policy ladder — what each class is worth

`LIVENESS_CLASSES` in `sql/30_build_intervals.sql` and `sql/90_reconcile.sql`. Full rebuild each.

| classes that renew liveness | intervals | hours | PEAK | Δ peak |
|---|---:|---:|---:|---:|
| playback lifecycle app_state error download ui | 30,323 | 1,978.1 | **2,917** | — **ships** |
| playback lifecycle download ui | 29,659 | 1,987.0 | 2,905 | −12 · −0.4% |
| playback lifecycle | 29,659 | 1,987.0 | 2,904 | −13 · −0.4% |
| playback download ui | 29,343 | 1,961.5 | 2,880 | −37 · −1.3% |
| playback | 29,340 | 1,961.5 | 2,879 | −38 · −1.3% |

**Cross-validation.** Rows 2 and 4 are exactly the `nobgfgerr` and `allowhb` variants of
[evidence/liveness/README.md](../liveness/README.md) Q1 — measured there on 2026-08-01 by a different
expression (`groupArrayIf(..., event_type NOT IN (...))`) in a different scratch database. They agree
to the interval: **29,659 / 1,987.0 / 2,905** and **29,343 / 1,961.5 / 2,880**. That agreement is what
licenses rows 3 and 5, which are new. Every row peaks at 2026-07-26 10:56 — consistent with the
adversarial audit: conventions move the peak's value, never its location, on this file.

The ladder is **not applied**. Narrowing it moves a submitted number and is an operator's call
([doubts/11](../../doubts/11-liveness-allow-list-unknown-events.md) is the dossier). The ladder exists
so that if a mentor rules, the ruling is a one-word edit with a number already attached.

## 2 · What the default is worth — three undeclared events, fail-open vs fail-closed

Each injects a **new** `(event_type, event)` pair into a copy of `ev_raw`, then rebuilds twice: once
with the pre-0033 model (every timestamp counts) and once with the contract. All three pairs are
plausible client telemetry; none is in `contracts/event_semantics.tsv`.

| injection | added events | fail-OPEN (pre-0033) | fail-CLOSED (ADR 0033) |
|---|---:|---|---|
| **A** `WidgetPing/ping`, every 30 s across each session's event span | +362,834 (+40%) | 29,219 · 1,988.6 h · **2,888** (−29) | 30,323 · 1,978.1 h · **2,917** |
| **B** `SystemSleep/lock-screen-ping`, every 60 s strictly inside each `AppBackgrounded`→`AppForegrounded` window — doubts/11's locked-phone hypothetical | +50,056 (+5.5%) | 29,349 · 1,962.3 h · **2,865** (−52 · −1.8%) | 30,323 · 1,978.1 h · **2,917** |
| **C** `AppKeepalive/tick`, every 30 s for 30 min after each session's last event | +651,960 (+72%) | 30,494 · **4,925.1 h** (+149%) · **5,004** (+2,087 · **+71.5%**), peak minute moves to **11:15** | 30,323 · 1,978.1 h · **2,917 @ 10:56** |

Under the contract the **interval boundaries are bit-identical to the baseline in all three cases**
(0 rows differ on `video_session_id, interval_start, interval_end, is_open`). The concurrency curve is
exactly invariant to vocabulary we have never declared.

**The direction is not predictable, which is the actual finding.** A and B *reduce* the peak: extra
liveness merges runs, and a longer run gives the 23% of pauses that never resume more room to eat
(`UNCLOSED_PAUSE_TO_RUN_END`, ADR 0007). C *inflates* it by 71.5%. So "unknown events fail open" is
not a bounded over-count that could be argued down — it is an **unbounded perturbation of unknown
sign**, and on the unseen day no gate would see it, because `sql/90_reconcile.sql` shares the model's
vocabulary by construction.

### The residual fail-closed does NOT remove

`dim_events` in `sql/30_build_intervals.sql` deliberately reads **every** row, because an undeclared
event still carries a true observation of the session's platform, country and language. So an
undeclared pair can still move a **filtered** answer even though it cannot move the total curve.
Measured under injection A (the most extreme), of 30,323 intervals:

```
audio_language   1,337    subtitle_language  1,311    player_version  965
platform            10    user_id                3    app_version/content_id/country  0
```

Stated, not fixed: gating dimension attribution on the contract would leave an undeclared-only
interval with no dimensions at all, which is worse. Probe 8 is what surfaces the pair.

## 3 · What a wrong classification costs — all 47 pairs, one at a time

The brief's counter-argument to fail-closed is that a wrongly-classified **common** event would be
expensive. Measured directly: 47 full rebuilds, each removing exactly one declared pair from the
liveness set (its `pause`/`resume`/`end` action, if any, left intact) and leaving the other 46.

| pair wrongly omitted | intervals | hours | PEAK | Δ peak |
|---|---:|---:|---:|---:|
| `VideoHeartbeat/network-bandwidth` | 30,178 | 1,885.4 | 2,786 | **−131 · −4.5%** |
| `AppForegrounded/AppForegrounded` | 29,796 | 1,966.0 | 2,890 | −27 · −0.9% |
| `VideoSessionStart/VideoSessionStart` | 30,159 | 1,957.0 | 2,900 | −17 · −0.6% |
| `VideoSessionEnd/VideoSessionEnd` | 30,155 | 1,975.2 | 2,910 | −7 |
| `VideoHeartbeat/network-activity` | 30,322 | 1,977.8 | 2,915 | −2 |
| `VideoHeartbeat/video-resize` | 30,403 | 1,975.8 | 2,915 | −2 |
| `VideoHeartbeat/buffer-health` | 30,325 | 1,977.9 | 2,916 | −1 |
| `VideoPlay/Play` | 30,314 | 1,977.9 | 2,916 | −1 |
| *37 further pairs* | | | 2,917 | **0** |
| `VideoHeartbeat/pause` | 30,332 | 1,978.2 | 2,918 | +1 |
| `AppBackgrounded/AppBackgrounded` | 30,195 | 1,999.7 | 2,935 | **+18 · +0.6%** |

**Range of a single misclassification: −131 to +18 peak; −92.7 h to +21.6 h.**

Two things follow, and both are load-bearing for the decision in ADR 0033:

1. **Volume is not weight.** The three highest-volume pairs — `network-activity` (19.6%),
   `buffer-health` (18.5%), `video-resize` (15.6%), **53.7% of the entire file between them** — are
   worth ≤2 peak each, because they are redundant with one another. `network-bandwidth` is 3.4% of
   events and worth 131. It is a *sparse-period* signal: of 5,247 gaps > 150 s between events that
   are not `network-bandwidth`, **1,170 (22%) contain a `network-bandwidth` event** that bridges
   them. It fires precisely when nothing else does.
   So "a wrongly-classified common event would be expensive" is true, but "common" means
   *load-bearing*, not *frequent* — and frequency is the thing a human reviewer will look at.
2. **The worst single misclassification (−4.5%) is smaller than the worst measured fail-open
   surprise (+71.5%)**, and unlike it, it is bounded, one-sided per pair, and visible: a
   misclassification is a line in a reviewed 47-line TSV, whereas fail-open is silent by definition.

## 4 · The alert is calibrated, not decorative

`tools/validate-source-contract.sh` probe 8 (promoted WARN → FAIL by ADR 0033) reports, besides the
new pairs and their counts, a `solo` figure: undeclared events with **no declared event within 150 s**
either side — the instants where fail-open and fail-closed genuinely disagree.

Run against a copy of the delivered file with `network-bandwidth` renamed to `thermal-throttle`
(i.e. the unseen day renames one sub-event, the exact case probe 5 is blind to because the
`event_type` is still known):

```
FAIL  undeclared (event_type, event) pair   30637   1 new pair(s), top: VideoHeartbeat/thermal-throttle x30637
      — GRANTS NO LIVENESS (ADR 0033 fail-closed), so the answer can only be UNDER-counted;
        2605 of 30637 such events across 3258 sessions have no declared event within 150s …
VERDICT: FAIL — 1 contract violation(s).
```

`solo = 2,605`, and §3 measures the actual cost of ignoring that pair at **−131 peak / −92.7 h**. The
probe's number is a live proxy for the money, produced before the load rather than after the score.

Against the injected `SystemSleep` file: `50,056` events / `5,085` sessions / `solo = 32,550`, plus a
probe-5 FAIL for the unknown type. Against the delivered file: `0`, verdict unchanged (WARN, 3
pre-existing warnings, 0 failures).

Cost of the probe: **0.14 s** on the 905,558-row file, **0.20 s** on a 955,614-row file carrying
50,056 undeclared events. One pass; the per-event neighbourhood scan only runs for sessions that
actually carry an undeclared pair.

## 5 · The drift tripwires, exercised

Both verified live, not asserted in a comment:

```
$ perl -i -pe "s/\['playback',…\] AS LIVENESS_CLASSES/['playback'] AS LIVENESS_CLASSES/" sql/90_reconcile.sql
$ tools/event-semantics.sh --check
event-semantics: FAIL model and gate declare DIFFERENT LIVENESS_CLASSES:
['playback','lifecycle','app_state','error','download','ui']
['playback']
exit=1

$ # delete one tuple from the generated block in sql/30_build_intervals.sql
$ tools/event-semantics.sh --check
event-semantics: FAIL sql/30_build_intervals.sql has drifted from contracts/event_semantics.tsv
exit=1
$ tools/event-semantics.sh --write && tools/event-semantics.sh --check
event-semantics: OK — 47 pairs, policy ['playback','lifecycle','app_state','error','download','ui'], in sync
```

`tools/test-all.sh --fast` with the contract in place: **9 suites, 9 PASS** (go-unit, evt-semantics,
golden, property, edge, landing, contract, truncation, load-guard). Every fixture and generator in the
repo emits declared vocabulary only — checked against `tests/edge/fixtures/*.sql`, `tools/golden-gen.sh`,
`tools/property-test.sh`'s `HB` list and `tools/scale-gen.sql`'s distribution-drawn LUT — so no suite
needed changing.

## Reproduction

```bash
# scratch DB pattern; graded database never written. Harness as evidence/liveness/README.md.
tools/ch "CREATE DATABASE IF NOT EXISTS evsem_q33"
# baseline / shipped: sql/30_build_intervals.sql with the table names rewritten
#   INSERT INTO session_intervals -> INSERT INTO evsem_q33.si_X ; FROM ev_raw -> FROM default.ev_raw
# policy ladder: edit the LIVENESS_CLASSES line before running
# misclassification: delete one tuple from the generated EVENT_SEMANTICS block before running
# injections: CREATE TABLE evsem_q33.ev_injX AS default.ev_raw, copy it, then INSERT the synthetic
#   pair (recipes in §2), and build from evsem_q33.ev_injX
# metrics: count() / sum(interval_end - interval_start) / arrayJoin(range(minute(start), minute(end)+60, 60))
#          with uniqExact(video_session_id), ORDER BY c DESC, m ASC LIMIT 1
tools/ch "DROP DATABASE evsem_q33"   # once the numbers stop being re-derived
```
