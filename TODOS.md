# TODOS — the task queue

> **Summary:** Pull from the top. `[H*]` marks the hour block from AGENT_WORKFLOW. Anything blocking
> the `/reconcile` gate outranks everything else. Keep this file honest — an agent picking up a dead
> session reads it first.

## Now

- [ ] **[H0]** Provision ClickHouse Cloud service; fill `.env`; `/verify-env` against Cloud
- [ ] **[H0]** Copy the two CSVs into `data/`; `docker compose up -d`; `tools/load.sh`
- [ ] **[H1]** Confirm the measured shape matches `docs/DATA_DICTIONARY.md` on OUR load
- [ ] **[H2]** Build `session_intervals` from heartbeat gaps — **one row visible end to end**

## Next

- [ ] **[H3]** `cc_minute_delta` + the MV that fills it; `v_concurrency_minute` view
- [ ] **[H4]** `/reconcile` passing on 5 minutes — **this is the gate, do not pass it by**
- [ ] **[H5]** Session-independent model + the comparison table (explicit deliverable)
- [ ] **[H6]** Peak/average at minute/hour/day grain with dimension filters
- [ ] **[H7]** ClickStack up, `tools/clickstack-bootstrap.sh`, ingestion-lag instrumented
- [ ] **[H8]** Open-session handling — truncate the file mid-stream and prove incremental absorption

## Then

- [ ] `/bench` on the full benchmark shapes; capture bytes read
- [ ] Minimal concurrency chart (out of scope to polish — just make it show the curve + freshness)
- [ ] ADRs for: interval representation, ordering key, watermark, open-session strategy
- [ ] Deck: 15 slides mapped to the five scoring criteria
- [ ] Rehearse the demo twice

## Blocked / needs a human

- [ ] **LICENSE** — ⚠ REMOVED for now at your request. It is a **required submission artifact**
      (MIT or Apache-2.0) and a missing one scores zero. Must be back before 12:00 Sunday.
- [ ] **Team Captain** — only they can submit. Confirm who, and that they are awake before the freeze.
