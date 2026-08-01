# ADR 0014 — Finalizer publication requires an external single-writer lease

> **Summary:** A ClickHouse finalizer run is a compare-and-stage workflow, not a transaction or lock
> service. Production scheduling must grant one fenced writer at a time and allocate a unique monotonically
> increasing run sequence outside MergeTree. Without this, concurrent runs can tie `argMax` versions and
> make correction state nondeterministic. Status: accepted, 2026-08-01.

**Status** Accepted · 2026-08-01

## Context

`finalize.sh` detects an existing prepared/staged run and derives its next sequence from the latest
published row. Those are useful crash guards for the single local operator, but two independent schedulers
can read the same state before either inserts. ClickHouse's production transaction support does not provide
the required multi-table compare-and-publish lock in this deployment.

## Decision

Run `finalize.sh` and `refresh-tail.sh` under one externally fenced leader. The production deployment
must use a singleton scheduler policy (for example, a Kubernetes CronJob with `concurrencyPolicy: Forbid`)
or a durable lease service that supplies an owner token and strictly increasing sequence. A new leader must
not publish until the prior lease is expired/fenced; the run log records the assigned sequence and owner in
the production adapter.

The local scripts remain intentionally simple for the hackathon's one-operator environment. They are not a
claim of safe multi-scheduler operation. A migration to Kafka/PubSub ingestion should allocate checkpoints
per source partition and couple the lease to the consumer generation/offset checkpoint.

## Consequences

- Concurrent finalizers are a deployment violation, not a race to resolve with `argMax`.
- The durable source contract must add partition/offset/event identity before high-rate production use.
- A correction stage is snapshot-bounded at its recorded source high-watermark, so resuming a prepared
  run cannot silently incorporate source rows that arrived after that checkpoint.
