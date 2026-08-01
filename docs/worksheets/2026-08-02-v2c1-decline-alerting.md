# Worksheet — 2026-08-02 · V2-C1 concurrency-decline alerting

**Goal** The statement's one optional item (`PROBLEM_STATEMENT.md:42`): detect concurrency decline
and tell apart the three causes it names — asset ended · system issue · content not engaging. The
deliverable is the *discrimination*, not the detection: an alert that fires on every legitimate
evening ramp-down is worse than no alert.

**Done**
- `tools/clickstack-alerts.sh` — idempotent provisioning of one dashboard (7 tiles), one webhook and
  **3 alerts** on hosted HyperDX, plus `--validate` (regenerates every threshold's evidence,
  read-only) and `--verify` (reads the alerts back signed-in). Detector + classifier SQL lives in
  this file as the single source of truth.
- `docs/DECLINE_ALERTING.md` — detector, baseline justification, the three-way classifier with
  measured thresholds, what was tested, what failed, and the LLM verdict.
- `evidence/alerting/detector-validation.txt` — 8 sections, all regenerable.
- `evidence/alerting/clickstack-alerts.txt` + `-BEFORE-having-fix.txt` — signed-in read-back, before
  and after the bug below.
- Doc healing in the same commit: `docs/CLICKSTACK.md`'s "No alerts, deliberately" claim is now
  false and says so; `docs/OBSERVABILITY.md` gains an alerting section; `AGENTS.md` routes to it.

**The design calls, with their measurements**
- Baseline = **median over [M-17, M-3]**, floored at 100 concurrent and 50 sessions. Fires **28** of
  6,195 minutes; a naive "down 20% vs 5 min ago" fires **962**, 918 of them below 10 concurrent.
- Lagged 3 min because an un-lagged baseline is dragged down by the decline it measures — detects
  the real episode at 11:13 instead of 11:16.
- Same-time-yesterday **rejected, measured**: 2,917 today vs 5 at the same minute the previous day.
- Classifier thresholds are anchored to semantics, not fitted: `end_coverage` 1.0 = every departure
  explained by an explicit close; `hb_per_session < 1.0` is *below the fully-paused rate* ADR 0007
  measured (0.756/min), so it cannot be viewer behaviour.
- Everything is watermark-anchored (`v_cc_watermark.sealed_watermark`), never `now()` — which is what
  makes an alert meaningful on a frozen file and correct on a live stream.

**The bug it found (and fixed)** Two alerts sat in `state=ALERT` while their tiles returned `0` — two
permanently-quiet alerts firing permanently. Two candidate causes, and we did **not** prove which:
`above` may be inclusive (the enum separately offers `above_exclusive`, so `0 >= 0` fires), or the
engine may trip on a row existing (a bare aggregate always returns one). Proving it would mean
mis-provisioning a live alert on purpose, so the fix closes both doors: `HAVING <count> > 0` (zero
rows when healthy) **and** `above_exclusive`. Verified by watching the state change live: both 15m
alerts cleared to `OK` at `21:45:03Z` while the 5m page *stayed* `ALERT` on its genuine 3 outage
minutes. Both captures committed.
**A 200 from the alerts API proves the alert was created, not that it works.**

**Not done, deliberately — read before claiming this works**
- **DISENGAGEMENT is shipped unvalidated.** No minute in the delivered file classifies as it, and
  that is not a tuning failure — `pausebg_per_session` never rises against its own baseline during
  the decline. Reported rather than tuned into existence. A gradual mid-asset decay on the unseen day
  would validate it in one command.
- **The only outage-shaped episode is the file's own truncation.** Last event is
  `2026-07-26 11:30:04.847`; everything after is model tail-grace. Correctly classified as an
  ingestion stoppage (a genuine page in production), but *not* a validated playback outage. The file
  has **0 unclosed sessions of 10,866** — the strongest outage signature does not occur in it at all.
- **No LLM in the detection path, on purpose.** It would be slower, non-deterministic and would fail
  plausibly. Where it would earn its place is turning a classified row into a sentence an on-call
  engineer acts on — scoped, not built, and argued in `DECLINE_ALERTING.md` §6.
- No seasonal baseline; the delivered file has no daily seasonality to fit one against.

**Graded DB** Read-only throughout. No `CREATE VIEW`, no writes, no `make model`. The detector is raw
SQL in control-plane tiles *because* `sonyliv` is read-only to us; on a deployment we owned it would
be `sql/95_decline.sql`.

**How to verify**
```bash
tools/clickstack-alerts.sh --validate   # every number in the doc, from the database
tools/clickstack-alerts.sh --verify     # the 3 alerts + 7 tiles, signed-in
tools/clickstack-alerts.sh              # re-provision; idempotent (updates, never duplicates)
```
Dashboard **SonyLIV concurrency decline** (`6a6e654ca561469a8f4eeab9`). The four counter tiles are
watermark-anchored and ignore the time picker; set the range to 2026-07-14 → 2026-07-26 for the curve
and detail tiles. Alerting tiles render **blank when healthy** — that is the fix, not a fault.
