# TODOS — the task queue

> **Summary:** Pull from the top. `[H*]` marks the hour block from AGENT_WORKFLOW. Anything blocking
> the `/reconcile` gate outranks everything else. Keep this file honest — an agent picking up a dead
> session reads it first.

## Now

- [ ] **[H0]** Provision ClickHouse Cloud service; fill `.env`; `/verify-env` against Cloud
- [ ] **[H0]** Copy the two CSVs into `data/`; `docker compose up -d`; `tools/load.sh`
- [ ] **[H1]** Confirm the measured shape matches `docs/DATA_DICTIONARY.md` on OUR load
- [x] **[H1] GATE ①** Heartbeats continue while backgrounded: 4,503 after the latest background marker.
      Gap-only logic is invalid; ADR 0007 makes background a hard state gate.
- [x] **[H1] GATE ②** `event` contains `pause`/`resume`; 94,463 heartbeats occur while paused and 6,868
      pause→resume gaps last at least one minute. Pause is a hard state gate (ADR 0007).
- [x] **[H1]** Source-contract preflight blocks ambiguous lifecycle reuse, invalid timestamps, unknown
      event types, tied serving-dimension conflicts, and missing content references before materialization.
- [ ] **[H1] GATE ③** Out-of-order arrival frequency — sets the watermark width `W`.
      Blocked by source telemetry, not SQL: supplied CSV has one bulk-load `ingested_at` timestamp.
- [x] **[H2]** Build state-gated `session_intervals` — 30,931 rows on the supplied load.

## Next

- [x] **[H3]** `cc_minute_delta` with **hour-clipped** emission + `v_concurrency_change`.
- [ ] **[H4]** `/reconcile` passing on 5 minutes — **implemented; capture Cloud evidence before checking off**
- [x] **[H4]** Finalizer + watermark metadata: published per-session correction state, checkpoint,
      resume protocol, and a synthetic late-background correction proven against raw re-derivation.
- [x] **[H4]** Open-session truncation gate: a 10:30 event-time cut retained 144 state-machine-open
      sessions, 75 active at the cut minute, and zero intervals beyond the 60-second tail bound.
- [x] **[H5]** Truncation test proving open-session absorption through a bounded exact tail.
      At a 10:30 cut, the staged tail serves all 75 active sessions and no interval extends past 60 seconds.
- [x] **[H4]** `PROJECTION` on `ev_raw` ordered by `video_session_id` — the finalizer and the
      straggler path are point lookups by session; `by_session` is present and selected in local
      `EXPLAIN indexes = 1`. Re-measure it on Cloud before benchmark evidence.
- [x] **[H5]** Bounded exact tail: versioned exact minute snapshot + stitched serving view (ADR 0012)
- [ ] **[H6]** Benchmark scoped additive hourly integrals and only exact peak cuboids. Do **not** sum
      per-dimension hour maxima for a filtered peak; ADR 0015 proves that loses time alignment.
- [ ] **[H7]** ClickStack up, `tools/clickstack-bootstrap.sh` — **instrument watermark lag**, not just ingestion lag
- [x] **[H8]** Straggler correction path (ADR 0006): synthetic late background marker changed the
      six-minute Android integral 1,841 → 1,836 and exactly matched an independent raw re-derivation.
- [ ] **[H8]** Tail-sensitivity sweep (gap × tail grid) — the ground truth is private and unfittable

## Then

- [ ] `/bench` on the full benchmark shapes; capture bytes read
- [ ] Minimal concurrency chart (out of scope to polish — just make it show the curve + freshness)
- [ ] ADRs for: the `video_session_id` projection, `video_type` materialisation
      (0001–0006 are written; 0001 is **conditional on GATE ①**; 0002 is main's, accepted + measured)
- [ ] Deck: 15 slides mapped to the five scoring criteria
- [ ] Rehearse the demo twice

## Blocked / needs a human

- [ ] **LICENSE** — ⚠ REMOVED for now at your request. It is a **required submission artifact**
      (MIT or Apache-2.0) and a missing one scores zero. Must be back before 12:00 Sunday.
- [ ] **Team Captain** — only they can submit. Confirm who, and that they are awake before the freeze.
