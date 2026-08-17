# From Batch Processing to Stream Processing

## Understanding events, messaging systems, and message brokers

In this blog we are going to explore about basics of stream processing and what are the places where stream processing is required.

## Batch Processing and the Need for Streams

One of the popular methods to process a bunch of data (technically stored in files) is Batch Processing. However, in batch processing the input is always know and finite. Before your batch process does any kind of processing like sorting the records, your system will be aware of all the records that are there to be processed, which implies, that your data structure (Mapreduce for example) will know its shortest and largest keys.

But a lot of applications are dynamic in nature, in which user generate data irregularly, data could flow after a minute, or after a second, or maybe even after a year. This uncertainty makes batch processing a bit inefficient to reflect the latest state of the system, for example, if your batch process is running at the end of the day, then the changes happening, from the start of the process to the next schedule of the process will be reflected in the next run, making your data stale.

One of the ways to deal with the dynamicity of data is to run the batch process more frequently, or maybe continuously in some cases, discarding the tradition time-slicing (Schedule) approach, this is the basic idea behind stream processing.

A stream refers to data that is incrementally made available over time, just like stdin and stdout of the Unix programming works.

In Unix, almost all hardware and communication channels are abstracted as files, there are low level integers defined as File Descriptor, hence there are dedicated channels defined even before the process loads into the kernel. Unix streams abstract input and output so data can be processed byte-by-byte as it arrives, making them strictly sequential, which means once a byte is passed there no possibility of rewind or seek backward.

> **Diagram placeholder:** Batch processing with finite input vs. stream processing with continuously arriving data.

## Transmitting Event Streams

There is some kind of input and output associated to all computer processes, similarly, there is for streams as well. An event is what goes into a stream as an input. But what is an event? The context of anything to be considered as an event is application dependent, but on the higher level, an event is a small, self-contained, immutable object containing the details of something that happened at some point time. It could creation of a new user profile on your application, or simply could be a click by the user on any UI component.

Events could be represented as JSON, or text strings, or any binary format, which makes it compatible to be stored in any relation table or document (application specific storage). The storage of an event makes it easier in a distributed system for it be sent or replicated to a multi node set-up. A producer (publisher or sender) generates an event and potentially this event can be consumed by multiple consumers(subscribed or recipients). The unique identifier of an event, or related events, in a streaming system would be a topic or stream.

> **Diagram placeholder:** A producer publishing events to a topic or stream, with multiple consumers subscribed to it.

At the simples level, a file or a datastore is sufficient to connect producers and consumers, a producer will write every event to the datastore and the consumer will periodically polls the datastore to check the occurrence of any new events. But as the application scales, and the uncertainty in the traffic being generated is introduced, the datastore bottlenecks could bring fallacies to the performance, while polling more often seems to be a one approach, but the more you poll a datastore, it becomes less likely to receive new events at the end of each poll.

A notification based approach could adhere to the bottleneck, where the consumers are being notified when a new event is generated, for example relational databases have triggers, which can react to a change (for example, insertion of a new row), but as these features are somewhat of an afterthought in database design, it could be have limitations for increasing scalability demands.

## Messaging Systems

A stream processing system supporting notifying consumer after a new event is received is knows as Messaging system. At the most basic level, a messaging can be implemented by a Unix pipe or TCP, and typically in such a system usually a one producer or a one consumer can be connected. As we talked that a single producer can publish an event to multiple consumers (topics) hence this approach is not sufficient to real world systems.

The publish-subscribe models digress to a multiple possibilities of failover mechanisms or approaches, mainly depending on the following scenarios:

1. The producers send messages faster than the consumer can process. For such kind of systems, the system can drop messages, buffer messages in a queue, or apply backpressure: by blocking the producer from sending more messages, Unix pipes and TCP use this approach. With queue based approach it is important to consider the fail over mechanisms when the queue fills up.

2. Crash down of nodes, or temporary downtime, message loss due to downtime: With databases, durability may require some combination of writing to disk and/or replication, which comes with cost. If the system can tolerate some message loss, then high throughput and low latency can be achieved with the same hardware.

> **Diagram placeholder:** Producer and consumer speed mismatch, showing drop, queue, and backpressure options.

## Direct Messaging from Producers to Consumers

Many messaging systems use direct network communication between producers and consumers. For example, UDP is used mostly in financial industry where low latency is very important (stock feeds), StatsD and Brubeck also uses UDP, even though UDP provides low latency but it is unreliable and can introduce packet loss over the network, making the job of application builders to have a failover mechanism to recover lost packets.

Brokerless messaging libraries like ZeroMQ, nanomsg used TCP for implementing publish-subscribe messaging. If the consumer exposes a service on the network, produces can make a direct HTTP or RPC request. The direct messaging systems work well but have limitations over a multiple situations like packet loss, consumer node downtime, which might require some implementations on the application side.

## Message Brokers

For more reliable streaming messaging, a lot of systems use a message queue, also know as a message broker. A message broker is a kind of database that is optimized for handling message streams. With complex streaming systems having a multi producer and multi consumer set-up, message broker, optimizes for multi client connect to tolerate crash, connect, disconnect scenarios. It runs as server, and each producer and consumer connect to it as client.

Depending upon the application requirements, these brokers can keep the messages in memory or write them over a disk. To cope up with slow consumers, they also support unbounded queueing.

The introduction of a message queue introduces asynchronicity into the system, as each producer or consumer, writes or consumes respectively to the message queue, eradicating the wait at the producer end for the message consumption.

> **Diagram placeholder:** Multiple producers and consumers connected asynchronously through a message broker.
