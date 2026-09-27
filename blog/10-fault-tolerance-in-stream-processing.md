# Fault Tolerance in Stream Processing

## Microbatching, checkpointing, atomic commit, idempotence, and state recovery

## Fault Tolerance

The issue of fault tolerance is not straight forward in case of streams. As streams are infinite and ever growing, waiting until a task is finished before making it output visible is not an option here.

## Microbatching and Checkpointing

One solution for fault tolerance is to break the stream into small batches and treat them like a mini batch process, called as microbatching.

It is used in spark streaming , the batch size is around 1 sec, which brings performance overhead with requiring more attention in scheduling and coordination, whereas longer batches could result in more delays before result is made available to the user.

Microbatching also provides the feature of tumbling window, where some information is needed from previous batch, can be obtained by a maintained state, carried over from one microbatch to another.

Another approach used in Apache Flink, is to periodically generates rolling checkpoints which are stored in a durable storage, and in case of a crash the processor can continue from the most recent checkpoint and by discarding any output generated between last checkpoint and the crash.

The checkpoint is triggered by barriers in message streams, similar to boundaries between microbatches, but without forcing a particular window size.

Checkpointing and microbatching in stream processing provides the exactly one-semantics. But as soon as the output leaves the stream processor, and goes to the target system (like cache, databases) this exactly one semantics is no longer guaranteed. Restarting a failed task can have side-effects also.

> **Diagram placeholder:** Microbatch boundaries compared with checkpoint barriers, followed by a processor crash and recovery from the most recent durable checkpoint.

## Atomic Commit

To make the system follow exactly-once processing even in the presence of faults, the side-effects and outputs of processing take effect only after the processing is done successfully.

Those effects not only include downstream systems like cache, push notifications but also acknowledgements around input messages like offset change for the consumer.

For this, all the changes need to happened atomically and should not go out of sync. The approach relies on writing the transaction commit as a single object to a fault-tolerant datastore, since a single-object write can be made atomic fairly easily.

## Idempotence

With the goal of exactly-once processing, all the partial output of the failed tasks should be discarded, one way to achieve this is via distributed transactions, but another way we can rely on is Idempotence.

An Idempotent operation is one that you can perform multiple times, and it has the same effect as if you performed it only once.

For example, setting a key in a key-value pair is an idempotent operation, if the key is updated to same value (identical) again and again there is going to no change visible , whereas incrementing a counter is not an idempotent as performing the increment again means the value is incremented twice.

Even if an operation is not naturally idempotent it can be made by using some metadata.

For example, consuming messages from kafka can be made idempotent by using an offset which is monotonically increases with each write. By this you can avoid performing the same update again by using the offset to get the last write done, the state handling in Storm's Trident is based on similar idea.

Idempotence implies that the operation is deterministic, no other node can concurrently update the same value and restarting a failed task must replay the same messages in the same order.

> **Diagram placeholder:** Retried writes showing an idempotent key assignment producing one visible result while a retried counter increment produces a duplicate effect.

## Rebuilding State After a Failure

Any stream that requires state (windowed aggregations like counters) must ensure that the state can be recovered after failure.

One option is to keep the state in a durable data storage, can be replicated to rebuild the state. This approach can be slow with the application requiring to query each message, to solve this the state could be stored locally over the disk, can be synced periodically. By this way, replication can be done without data loss,=.

Flink use snapshots of operator state using durable storage like HDFS, whereas, Kafka Streams replicate state changes by sending them to a dedicated kafka topic with log compaction.

In some cases the replication might not be needed via state, where it can be rebuilt by replaying input streams. For example, if the state consists of aggregations over a fairly short window, it may be fast enough to simply replay the input events corresponding to that window.

> **Diagram placeholder:** Recovering operator state through a durable snapshot, a compacted state topic, or replaying the input events for a short window.
