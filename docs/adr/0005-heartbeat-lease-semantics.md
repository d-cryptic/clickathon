# ADR 0005 — Heartbeat lease semantics for the hot tier (superseded)

> **Summary:** In the hot tier ([ADR 0004](0004-two-tier-lambda-serving.md)) a session is active in
> minute M iff some heartbeat lease covers M, where each heartbeat at `t` grants `[t, t + LEASE)` and
> `LEASE = HEARTBEAT_GAP_S`. This is provably identical to the gap model everywhere except the tail,
> where the lease credits `LEASE` seconds past the last beat rather than `TAIL_GRACE_S` — an
> unavoidable consequence of streaming, since you cannot know a beat was the last one until the gap has
> elapsed. Aggregation is `uniqExact`, never `uniq`. Status: proposed, 2026-08-01.

**Status** Superseded by [ADR 0007](0007-state-gate-heartbeats.md) · 2026-08-01

## Context

The lease is not authoritative because a stateless MV cannot know app/playback state established in a
previous insert block. Measured backgrounded and paused heartbeats make that omission incorrect; see
ADR 0007.

The hot tier must be computable by a stateless materialized view: no reading of prior state, no
knowledge of a session's earlier heartbeats, idempotent under replay and late arrival. The gap model
from [ADR 0001](0001-heartbeat-gaps-over-background-events.md) cannot satisfy this — closing an
interval on a gap requires knowing the previous beat's timestamp, which is cross-block state.

## Decision

Each heartbeat at time `t` grants a **lease** over `[t, t + LEASE)`, with `LEASE = HEARTBEAT_GAP_S`
(currently 150s). The MV `arrayJoin`s the beat into every minute bucket the lease covers — with a 60s
cadence and a 150s lease that is 3 buckets — and accumulates
`uniqExactState(video_session_id)` per `(dims, minute)`. A session is active in minute M iff its
`uniqExact` set contains it.

**`uniqExact`, not `uniq`.** The existing `cc_minute_stateless` used `AggregateFunction(uniq, String)`,
which is a HyperLogLog-family estimator carrying roughly 1–2% error. Against an *exact*, private ground
truth that is a silent correctness bug on every number passing through it. Memory cost is proportional
to distinct sessions per bucket, which is entirely affordable at minute grain.

## Why

**Equivalence to the gap model in the interior.** Two consecutive beats separated by `d ≤ LEASE`
produce leases that overlap, so coverage is continuous. That is exactly the gap model's rule ("a gap
greater than `HEARTBEAT_GAP_S` closes the interval"). A single missed beat — 120s apart at 60s cadence
— is bridged by both models identically, because 120 < 150. When `d > LEASE`, the first lease expires
before the next beat arrives and coverage breaks, which is the gap model closing the interval. The two
agree on every interior minute.

**Divergence at the tail, and why it is irreducible.** After the final beat at `t_last`, the lease
model credits activity until `t_last + LEASE`; the gap model credits until `t_last + TAIL_GRACE_S`.
With the current 150s/60s tunables that is a 90-second overcount per interval close. This is not a bug
to fix but the fundamental limit of streaming: at the moment `t_last + 60s` arrives, no observer can
yet distinguish "this session stopped" from "the next beat is slightly late". Only the passage of
`LEASE` settles it — which is precisely what the sealed tier waits for.

**Idempotence.** `uniqExact` is monotone and set-based, so inserting the same heartbeat twice is a
no-op and inserting one out of order is a pure addition. This is what makes the hot tier need no
compensation mechanism at all.

## Consequences

- The hot tier **overcounts by a bounded amount** — at most `LEASE − TAIL_GRACE_S` per interval close,
  and only for minutes inside the hot window. Report this in the comparison panel; do not hide it.
- The hot tier **cannot retract**. A `VideoSessionEnd` arriving mid-lease cannot subtract from a uniq
  state. The session lingers until its leases expire. Same bound, same disclosure.
- `LEASE` is deliberately tied to `HEARTBEAT_GAP_S` so the two tiers cannot drift apart. If they are
  ever decoupled, the equivalence argument above no longer holds and this ADR must be revised.
- The `arrayJoin` fan-out is `ceil(LEASE / 60)` rows per heartbeat — 3 at current tunables. At 93% of
  events being heartbeats this roughly triples hot-tier insert volume, which is why the hot tier is
  TTL'd to a short window and never holds history.
- If the §3.4 gating measurement shows heartbeats **continue during backgrounding**, this ADR is
  affected exactly as much as ADR 0001 is: leases would keep renewing through a background period and
  the hot tier would count backgrounded users as active. Both models would need the state-machine
  layer. The lease mechanism itself survives; only the definition of which events grant a lease changes.
