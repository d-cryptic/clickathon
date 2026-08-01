# Publish-time read visibility — the mid-publish dip, reproduced, sized, and fixed in prototype

> **Summary:** Codex 003 §7.3.5/§7.3.9 claimed a reader can observe a concurrency dip while a
> publish is in flight, and that the tiers can disagree. Both reproduced here on Cloud 26.2.1.525 in
> scratch db `sonyliv_q29vis`: the minute tier dropped **2,825 → 344 (−87.8%) for ~13.6 s** during a
> realistic 7,723-session catch-up publish, and **2,825 → 2,525 (−300, exactly the forced batch's
> contribution)** for ~11.4 s in a controlled run; hour and user tiers lagged the minute tier's
> recovery by a further **3.8 s and 7.3 s**. A staged one-block correction (experiment 3) removed
> the dip entirely — 0 deviating samples, single part written. Decision + handoff: **ADR 0023**.

## The claim under test

`tools/publish.sh` (ADR 0013/0016) publishes in eight phases. The `negated` phase appends
`-deltas(old)` to the serving table `cc_minute_delta`; the `emitted` phase appends `+deltas(new)`
**three statements later**. Any reader landing between them sees the claimed sessions' entire
contribution missing. The convergence gate (`tools/publish-test.sh compare`, `/reconcile`) runs
*between* publishes, so it can never observe this state.

## Files

| File | What it is |
|---|---|
| `00-setup.sh` / `00-setup.txt` | Scratch db `sonyliv_q29vis`: schema + truncated slice (< 10:56) + bootstrap publish. `sonyliv` read-only throughout. |
| `10-dip-forced.sh` / `.txt` | **Experiment 1 — deterministic.** Force-republish 300 *unchanged* sessions covering probe minute 10:54 while a poller reads all 3 tiers. True answer never moves, so any deviation is pure visibility artifact. |
| `10-poll-forced.tsv` | 60 poller samples. Dip: 2,825 → 2,525 from 17:42:47.380 to 17:42:58.467 (≈ 11.1–11.5 s observed; 11.38 s negate-finish → emit-finish server-side). |
| `20-dip-realistic.sh` / `.txt` | **Experiment 2 — realistic.** Land the whole remaining stream (7,723 sessions) as one late batch; poll a published minute (probe A, 10:54) and an incoming minute (probe B, 11:30). |
| `20-poll-realistic.tsv` | 52 samples. Probe A: 2,825 → **344** for 13.6 s (negate 17:45:05.240 → emit 17:45:18.844). Probe B: minute tier jumps to 197 at emit; hour tier reads **no row** until +3.8 s; user tier reads 0 until +7.3 s. |
| `30-oneblock-fix.sh` / `.txt` | **Experiment 3 — the fix, prototyped.** Same forced batch as exp 1, but corrections staged in `q29_stage`; `cc_minute_delta` receives ONE insert (−old ∪ +new). Poller: **0 of 9 samples deviated**. Swap: 79 ms, 2,440 rows written, **one part** (optimize_on_insert collapsed the ± pairs to 1,220 rows before the part hit disk). Converges to 2,825 exactly. |
| `30-poll-oneblock.tsv` | The no-dip samples. |

## The four numbers that matter

| Measurement | Value |
|---|---|
| Dip magnitude, realistic batch (probe minute inside claimed coverage) | −2,481 of 2,825 = **−87.8%** |
| Dip magnitude, controlled batch | exactly the claimed sessions' contribution (−300 of −300) |
| Dip window (negate visible → emit visible) | **11.4 s** (300 sessions) / **13.6 s** (7,723 sessions) — of which only 1.4–2.5 s is statement time; the rest is publish.sh's between-phase bookkeeping (`written_rows` runs `SYSTEM FLUSH LOGS` per phase) |
| Cross-tier lag after minute tier recovers (ADR 0016 phases) | hour tier **+3.8 s**, user tier **+7.3 s**; during it, tiers disagree categorically (minute 197 vs hour/user "no row") |

## Reproduce

```bash
evidence/publish-visibility/00-setup.sh        # ~2 min, builds sonyliv_q29vis
evidence/publish-visibility/10-dip-forced.sh   # ~40 s
evidence/publish-visibility/20-dip-realistic.sh # ~90 s (loads rest of stream — rerun 00 first to reset)
evidence/publish-visibility/30-oneblock-fix.sh # ~30 s
tools/ch -c "DROP DATABASE IF EXISTS sonyliv_q29vis"   # cleanup
```

Nothing here writes `sonyliv`; each script greps itself for prod writes and refuses to run.
