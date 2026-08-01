# ClickHouse Hackathon - Solution Design, Evaluation & Stress Testing Guide

> Consolidated from handwritten notes. This document serves as a checklist while designing, implementing, benchmarking, stress testing, and defending the proposed solution.

---

# 1. Problem Understanding

The objective is **not just to count sessions**, but to accurately answer:

> **"How many sessions overlap at a given minute?"**

Key observations:

- User activity is **dynamic**, not static.
- Active ranges evolve continuously as new events arrive.
- Solution should represent activity efficiently while supporting continuous updates.
- Think from a **Data Engineer's POV**, not only as an algorithm problem.

---

# 2. Core Data Model

## Interval Representation

Understand:

- What is an **active interval**?
- How are active ranges represented?
- What constitutes session start?
- What constitutes session end?
- How are heartbeats incorporated?

Possible interval definition:

```
Session =
Start Time
End Time
Heartbeat events
Background/Idle Periods
```

Need a precise definition before implementation.

---

# 3. Computational Model

The computational model should answer:

- How is concurrency computed?
- How are overlapping intervals calculated?
- How is the model updated as new data arrives?
- How does the computation evolve over time?

The solution should avoid treating sessions as immutable.

---

# 4. Storage Model

Consider whether aggregates should be:

- Session-aware
- Session-independent

Possible storage strategies:

## Aggregate Tables

Pros

- Faster queries
- Better scalability

Need to evaluate:

- Update friendliness
- Query efficiency

---

## Materialized Views

Potential usage:

- Pre-processing
- Cleaning erroneous data
- Maintaining derived aggregates

Questions:

- What should be materialized?
- What should remain raw?
- Can preprocessing eliminate expensive runtime work?

---

# 5. Interval vs Delta Model

Evaluate whether the solution should use:

## Interval Model

Pros

- Natural representation
- Easier reasoning

Cons

- Expensive overlap computation

---

## Delta/Event Model

Represent:

```
Session Start  -> +1
Session End    -> -1
```

Advantages:

- Prefix sums
- Efficient concurrency computation
- Incremental updates

Need comparison:

- Complexity
- Storage
- Update cost
- Query performance

---

# 6. Query Requirements

The model should efficiently support queries like:

- Per minute
- Per hour
- Per day

Metrics:

- Peak concurrency
- Average concurrency

Benchmark queries should cover all these granularities.

---

# 7. Expected Filters

Design schema assuming users will filter by:

- Time
- Minute
- Hour
- Day

Potential future filters should also be anticipated.

Schema should remain filter-friendly.

---

# 8. Large Scale Considerations

The design should be:

- Query efficient
- Update friendly
- Suitable for large datasets
- Scalable under continuous ingestion

Avoid solutions that only perform well on static datasets.

---

# 9. Handling Updating Data

Critical consideration.

Sessions continue receiving events.

Need strategy for:

- Updating active sessions
- Finalizing sessions
- Late arriving events
- Incremental aggregation

Possible approach:

- Keep finalized data aggregated
- Keep active sessions mutable
- Merge after completion

---

# 10. Handling Open Sessions

One important judging question:

> How do you handle sessions that are still ongoing?

Examples:

- No end timestamp
- Continuous heartbeat
- Live session

Need clearly defined behavior.

---

# 11. Heartbeat Handling

Heartbeats determine active state.

Need to define:

- Heartbeat interval
- Missing heartbeat handling
- Session timeout
- Background idle period
- Session continuation rules

---

# 12. Aggregate Strategy

Need to justify:

Why aggregate?

Possible benefits:

- Lower query latency
- Reduced computation
- Better scalability

Need to explain:

- Refresh strategy
- Update mechanism
- Consistency guarantees

---

# 13. Data Cleaning

Dataset may contain:

- Empty strings
- NULL values
- Duplicate records
- Erroneous data

Need preprocessing pipeline.

Possible implementation:

- Materialized Views
- Cleaning during ingestion
- Validation layer

---

# 14. Benchmarking

Prepare benchmark query set.

Should include:

- Peak concurrency
- Average concurrency

Across:

- Minute
- Hour
- Day

Measure:

- Query latency
- Throughput
- Resource usage

---

# 15. Stress Testing Checklist

Test:

## High Volume

- Millions of sessions
- Billions of events

---

## High Update Rate

- Continuous heartbeats
- Frequent session updates

---

## Concurrent Queries

- Multiple analytical queries
- Simultaneous ingestion

---

## Long Running Sessions

Sessions lasting:

- Hours
- Days

---

## Bursty Traffic

Many sessions:

- Start simultaneously
- End simultaneously

---

## Late Data

- Delayed events
- Out-of-order events

---

## Duplicate Events

Verify:

- Idempotency
- Deduplication

---

## Missing Events

Examples:

- Missing heartbeat
- Missing end event

---

# 16. Edge Cases

Must explicitly define handling for:

- Empty strings
- NULL timestamps
- Duplicate records
- Missing session end
- Missing heartbeat
- Invalid intervals
- Zero-length sessions
- Out-of-order events
- Overlapping duplicate sessions

---

# 17. Optimization Checklist

The solution should be:

- Query efficient
- Update friendly
- Incrementally maintainable
- Scalable
- Suitable for continuous ingestion
- Filter efficient
- Aggregation friendly

---

# 18. Judgement Criteria (Expected)

Judges are likely to evaluate:

## Correctness

- Accurate concurrency computation
- Correct interval handling
- Proper session definition

---

## Scalability

- Large dataset support
- Continuous ingestion
- Efficient updates

---

## Query Performance

- Low latency
- Efficient filtering
- Aggregate performance

---

## Data Modeling

- Sound schema
- Appropriate computational model
- Well justified aggregate design

---

## Robustness

- Handles erroneous data
- Handles open sessions
- Handles duplicates
- Handles missing values

---

## Practicality

Solution should deliver real business value.

Consider:

- Is it useful for actual analytics?
- Can businesses rely on it?
- Does it scale in production?

---

# 19. Questions You Must Be Ready to Answer

## Interval Model

- What is your interval definition?
- How are active ranges represented?

---

## Computation

- How do you compute overlap accurately?
- How do you compute average concurrency?
- How do you compute peak concurrency?

---

## Updates

- How do you update active sessions?
- How do you finalize sessions?
- How do you process late events?

---

## Open Sessions

- How do you represent sessions without an end time?
- How do you query ongoing sessions?

---

## Aggregation

- Why aggregate?
- Why this aggregation strategy?
- Why materialized views?

---

## Storage

- Aggregate table or raw table?
- Session-aware or session-independent?
- Why this schema?

---

## Performance

- Why is your model query efficient?
- Why is it update friendly?
- Why is it scalable?

---

## Data Quality

- How are duplicates handled?
- How are NULLs handled?
- How are erroneous records cleaned?

---

## Benchmarking

- Which benchmark queries did you run?
- What metrics did you measure?

---

## Business Perspective

- Why is this solution valuable?
- What business problem does it solve?
- How would it be deployed in production?

---

# 20. Final Submission Checklist

- [ ] Clearly define active interval
- [ ] Explain session lifecycle
- [ ] Justify schema design
- [ ] Justify interval vs delta model
- [ ] Explain computational model
- [ ] Handle open sessions
- [ ] Handle late-arriving events
- [ ] Handle heartbeats
- [ ] Handle duplicates
- [ ] Handle NULLs and empty values
- [ ] Describe preprocessing pipeline
- [ ] Justify materialized views
- [ ] Explain aggregate tables
- [ ] Demonstrate scalability
- [ ] Benchmark minute/hour/day queries
- [ ] Benchmark peak & average concurrency
- [ ] Demonstrate filter efficiency
- [ ] Demonstrate update efficiency
- [ ] Explain business value
- [ ] Be prepared to defend every design decision

---

# 21. End-to-End Data Pipeline

## Input Datasets

### 1. Current Data (Metadata)

```
ch-hackathon-current-data.csv
```

Contains:

- Session metadata
- Current session state
- Supporting metadata

---

### 2. Raw Event Data

```
ch-hackathon-raw-data.csv
```

Contains:

- Active events
- Raw event stream
- Heartbeats
- Session activity

---

## Data Flow

```
Current Metadata
        +
Raw Event Stream
        │
        ▼
       JOIN
        │
        ▼
 Preprocessing / Validation
        │
        ▼
 Aggregate Tables
```

---

# 22. Aggregate Table Design Alternatives

Two candidate approaches should be implemented or evaluated.

## Option 1 — Session-Aware Aggregation

Aggregate tables maintain explicit knowledge of session boundaries.

Characteristics:

- Uses your interval definition
- Stores session lifecycle
- Better semantic correctness
- Easier handling of heartbeats
- Better for interval-based analytics

Questions:

- How expensive are updates?
- How large do aggregates become?
- Does session mutation affect performance?

---

## Option 2 — Session-Independent Aggregation

Aggregate tables ignore session objects and focus only on activity.

Characteristics:

- Calculates active frequencies
- Event-centric
- Simpler aggregation
- Potentially lower update cost

Questions:

- Does accuracy decrease?
- Can all concurrency metrics still be derived?
- How much information is lost?

---

# 23. Compare Aggregation Strategies

The solution should compare both models.

Evaluation criteria:

- Accuracy
- Query latency
- Update latency
- Storage cost
- Complexity
- Scalability
- Ease of maintenance

Goal:

> Determine which approach provides the best trade-off between accuracy, scalability, and operational simplicity.

---

# 24. Real-Time Processing Pipeline

Once aggregate tables are ready, the system should support continuous ingestion.

Pipeline:

```
Incoming Events
        │
        ▼
Validation
        │
        ▼
Error Detection
        │
        ▼
Real-time Filtering
        │
        ▼
Aggregate Update
        │
        ▼
Continuous Publishing
```

---

# 25. Event Ingestion Strategy

The ingestion layer should support:

- Continuous event arrival
- Valid events
- Erroneous events
- Real-time filtering
- Incremental aggregate updates

The pipeline should avoid expensive recomputation whenever possible.

---

# 26. Continuous Publishing

The architecture should continuously publish updated aggregates instead of waiting for complete batch execution.

Desired properties:

- Low latency
- Incremental updates
- Near real-time analytics
- Query-ready aggregates

---

# 27. Accuracy vs Trade-off Analysis

An important judging aspect will likely be demonstrating that multiple approaches were considered.

Prepare a comparison similar to:

| Criteria | Session Aware | Session Independent |
|-----------|---------------|---------------------|
| Accuracy | Higher | Moderate |
| Update Cost | Higher | Lower |
| Query Performance | Depends on aggregation | Faster |
| Storage | Higher | Lower |
| Complexity | Higher | Lower |
| Scalability | Moderate | High |

Explain **why your chosen approach is preferable** instead of simply presenting it.

---

# 28. Architecture Decision Checklist

Before finalizing the solution, ensure you can justify:

- [ ] Why join metadata with raw events?
- [ ] Why this preprocessing strategy?
- [ ] Why aggregate tables?
- [ ] Why session-aware or session-independent aggregation?
- [ ] Why this interval definition?
- [ ] Why this update mechanism?
- [ ] Why this filtering strategy?
- [ ] Why this publishing mechanism?
- [ ] What are the trade-offs compared to alternative designs?

---

# 29. Suggested Overall Architecture

```
Current Metadata CSV
            │
            │
            ├──────────────┐
            │              │
            ▼              ▼
      Metadata Join   Raw Event Stream
              │
              ▼
      Validation & Cleaning
              │
              ▼
      Real-time Filtering
              │
              ▼
      Aggregate Tables
       ├───────────────┐
       │               │
       ▼               ▼
Session-aware     Session-independent
Aggregation       Aggregation
       │               │
       └──────┬────────┘
              ▼
      Benchmark & Compare
              ▼
   Continuous Query Serving
              ▼
 Real-time Publishing / Dashboard
```

---

# 30. Final Principle

The solution should not only compute concurrency correctly but also demonstrate **production-grade data engineering practices**:

- Robust ingestion
- Efficient preprocessing
- Incremental aggregation
- Real-time updates
- Scalable query execution
- Clear trade-off analysis
- Defensible architectural decisions

The judges are likely to value **why** a particular design was chosen as much as **how** it was implemented.

---

# Golden Rule

The winning solution should optimize **both ingestion and querying** while maintaining **correctness, scalability, and robustness**. Every design choice—schema, interval representation, aggregation strategy, materialized views, and computational model—should be defensible in terms of **performance, maintainability, and real-world business value**, not just algorithmic correctness.