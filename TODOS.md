# TODOS — the task queue

> **Summary:** Pull from the top. `[H*]` marks the hour block from AGENT_WORKFLOW. Anything blocking
> the `/reconcile` gate outranks everything else. Keep this file honest — an agent picking up a dead
> session reads it first.

## Now

- [ ] **[H0]** Provision ClickHouse Cloud service; fill `.env`; `/verify-env` against Cloud
- [ ] **[H0]** Copy the two CSVs into `data/`; `docker compose up -d`; `tools/load.sh`
- [ ] **[H1]** Confirm the measured shape matches `docs/DATA_DICTIONARY.md` on OUR load
- [ ] **[H1] GATE ①** Do heartbeats continue while backgrounded? Count beats strictly inside each
      bg→fg pair. **≈0 → ADR 0001 stands. ≈1/min → gaps are blind and the model becomes a hybrid.**
      Nothing past H2 starts until this is answered.
- [ ] **[H1] GATE ②** Census the `event` sub-column for pause states; do heartbeats survive a pause?
      The statement excludes paused time explicitly and we have no handling for it.
- [ ] **[H1] GATE ③** Out-of-order arrival frequency — sets the watermark width `W`.
- [ ] **[H2]** Build `session_intervals` from heartbeat gaps — **one row visible end to end**

## Next

- [ ] **[H3]** `cc_minute_delta` with **hour-clipped** emission (ADR 0003) + `v_concurrency_minute`
- [ ] **[H4]** `/reconcile` passing on 5 minutes — **this is the gate, do not pass it by**
- [ ] **[H4]** Finalizer + watermark; truncation test proving open-session absorption.
      ← **MVP LINE: sealed tier + stateless baseline is a complete submission from here**
- [ ] **[H5]** Hot tier: `mv_lease` → `cc_minute_hot` (`uniqExact`) + the stitched serving view (ADR 0004/0005)
- [ ] **[H6]** `cc_hour_agg` (max + integral); peak/average at minute/hour/day grain with dimension filters
- [ ] **[H7]** ClickStack up, `tools/clickstack-bootstrap.sh` — **instrument watermark lag**, not just ingestion lag
- [ ] **[H8]** Straggler correction-by-diff path (ADR 0006) + the live late-arrival demo
- [ ] **[H8]** Tail-sensitivity sweep (gap × tail grid) — the ground truth is private and unfittable

## Then

- [ ] `/bench` on the full benchmark shapes; capture bytes read
- [ ] Minimal concurrency chart (out of scope to polish — just make it show the curve + freshness)
- [ ] ADRs for: ordering key, projection hedge, `video_type` materialisation
      (0001–0006 are written; 0001 is **conditional on GATE ①**)
- [ ] Deck: 15 slides mapped to the five scoring criteria
- [ ] Rehearse the demo twice

## Blocked / needs a human

- [ ] **LICENSE** — MIT is in place as a default; confirm or switch (`Apache-2.0`). Required artifact.
- [ ] **Team Captain** — only they can submit. Confirm who, and that they are awake before the freeze.
