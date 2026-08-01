# ADR 0007 — State-gate heartbeats before sessionizing

> **Summary:** A heartbeat is evidence of transport activity, not sufficient evidence of foreground
> playback. Build active intervals from heartbeats only while the app is foregrounded and playback is
> not paused; `AppBackgrounded`, `pause`, and `VideoSessionEnd` cut intervals immediately.
> Measured on the supplied data: 4,503 heartbeats arrive while backgrounded and 94,463 while paused.

**Status** Accepted · 2026-08-01 · supersedes ADR 0001's primary-signal decision

## Context

ADR 0001 assumed heartbeat gaps alone were enough because background/foreground pairs are incomplete.
The gate measurement disproves that assumption: heartbeats continue in backgrounded and paused states.
Ignoring the state markers would count known-inactive time.

## Decision

Maintain two independent event-time state machines per session: app foreground/background and
playback playing/paused. A `VideoHeartbeat` is eligible only when both states are active. Gaps greater
than 150 seconds split eligible heartbeat runs; the final eligible heartbeat receives 60 seconds of
tail credit. Stop markers cap an interval at their own timestamp rather than at tail expiry. `VideoError`
is an annotation, not a terminal state: 743 heartbeat rows follow an error in the supplied stream.

`AppForegrounded` and `resume` change eligibility but are not themselves proof of playback; a fresh
heartbeat starts the next active interval. Missing foreground/resume events therefore fail closed,
while unmatched background/pause events remain safe.

## Evidence

The supplied load contains 4,503 heartbeat rows after the most recent background marker and 94,463
after the most recent pause marker. There are 6,868 pause-to-resume intervals at least a minute long.
The implementation's cut-point audit finds zero stop markers strictly inside a stored active interval.

## Consequences

- The interval builder is an event-time state machine, not gap detection alone.
- A streaming MV cannot be the authoritative interval builder: it receives only one insert block and
  cannot know state established in another block.
- The planned hot tier must be a bounded session-aware tail, not an ungated `uniqExact` heartbeat MV.
