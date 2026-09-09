# Partitioned Logs, Consumer Offsets, and Replay

## Combining durable storage with low-latency messaging

## Partitioned Logs

Sending messages over the network is mostly a transient operation, having no permanent trace. Even the message brokers that write messages to the disk, also delete the data after the message has been successfully processed by the consumer.

Due to this reason, the same message to be consumed multiple times by the broker can be a destructive operation if it causes the message to be deleted from the broker, in simple words, you cannot run the same consumer again and expect to get the same result.

When a new consumer is added to a messaging system, it starts receiving messages from the time it was registered, and it does not hold any prior messages that where consumed or any other prior information. Whereas in a database, a newly added client would also have the data from the past to make it consistent with the existing clients.

When we combine durable storage approach of databases with low-latency notification feature of messaging system, such kind of brokers are known as log-based message brokers.

## Using Logs for Message Storage

A log is simply an append-only sequence of records on disk. In a log based message broker, a producer sends a message by appending it to the end of the log, and a consumer receives messages by reading the logs sequentially. And when a consumer reaches the end of the log, it will wait for a notification that a new message has been appended. The working mechanism is similar to Unix tool tail -f.

A single disk will have performance limitations, to scale it up, the logs can be partitioned. Different partitions can be hosted on different machines, and several partitions can be grouped together under a single topic.

Within each partition, each message will be assigned a sequentially increasing (monotonic) number. This way ordering of messages can be preserved in each partition, whereas ordering across different partitions is not guaranteed.

> **Diagram placeholder:** One topic split into multiple log partitions on different machines, with monotonically increasing offsets and ordering guaranteed only within each partition.

## Logs Compared to Traditional Messaging

The log based approach supports fan-out messaging, because several consumers can independently read the log without affecting each other. For load balancing, the broker can assign entire partitions to nodes in the consumer group. Each client reads the messages from the assigned log partition sequentially, in a single threaded manner.

It has following disadvantages:

The number of nodes sharing the work of consuming a topic can be at most the number of log partitions in that topic, because messages within the same partition are delivered to the same node, if a single message is slow to process , then it will make the whole process quite slow with the rest messages waiting in line to get processed.

Hence, in situations where messages are heavy to process , and parallelization is required then JMS/AMQP style of message brokers are preferrable whereas on the other hand where each message is very fast to process and message ordering is crucial, log based approach is preferrable.

## Consumer Offsets

Consuming partition sequentially reduces the overhead for bookkeeping by acknowledgements as with consumer offsets it is easy to tell what messages have been processed, the messages having offset less then the consumer offset have been processed and the one having greater offsets are yet to be processed.

If a consumer node fails, then the other healthy consumer from the same consumer group is assigned to process the failed consumer's partitions, and the tracking is easy with the recorded offsets. But if the offset recording fails then the same messages will get processed twice.

## Disk Space Usage

If the eco-system only appends the log, then there is a high chance that you'll run out of disk space, To reclaim disk space with growing messages, the log is divided into segments, from time to time old segments are deleted or moved to archive storage.

If a consumer can not keep up with the message pace, then it's offset is going to point to the offset of a deleted segment. Logs have buffering that discards old messages when the buffer is full, know as circular buffer or ring buffer. The risk to mind the buffer size to be too large as it is on a disk.

Alerting can be set-up if the consumer lags behind the head of the lag, since the buffer is large, it gives ample time to fix issues and bring the faulty consumer up to speed, even if the lag is quite huge, a multi consumer set-up delivers the speed with other healthy consumers.

## Replaying Old Messages

The log based approach is more like a read only operation which does not change the log, the consumer offset always move forward. The offset being in consumer's control can be always manipulated, for example you change the offset with yesterday's offset to replay the messages, it increases the room of experimentation and easier recovery from errors and bugs.
