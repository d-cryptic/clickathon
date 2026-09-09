# Message Brokers, Consumers, and Reliable Delivery

## How brokers differ from databases, distribute work, and redeliver messages

## Message Brokers Compared to Databases

Even though some message brokers can participate in 2-phase commit protocols using XA, making them similar to databases, but they are various characteristics in which a message broker differ from a traditional database.

Databases keep the data forever, until a user explicitly deletes it, where as a message broker is know to erase the data once it is delivered to a consumer. Since data is short lived in a message broker, the size of the queue is kept generally of reasonable size, so in a case of slow consumer, the overhead makes the processing of each message slower hence degrading the performance.

Databases have indexes to support fast and improved searching, whereas a message broker provides the feature to subscribe to a subset of topic based on some pattern match, even though the implementation of both the functionalities is different the core feature of selecting some data out of the superset is supported in both.

The results of queries in a database are based out of in-point snapshot, so in the scenarios when the database updates within the time period a query is being executed, the query is going to return a stale result (unless there is polling mechanism maintained) where as a message broker don’t support arbitrary query but do notify the clients when data changes.

## Multiple Consumers

In a many: one consumer to topic mapping set-up, the following pattern of messaging are used:

### Load Balancing

Load Balancing: each message is delivered to one of the consumers in the pool, and the consumers share the work of processing the topic. The broker assigns the message arbitrary to a consumer, this approach is suitable for scenarios where processing of a message is a complex task and it is desired to parallelize the processing of the message. AMQP support this by having multiple clients, JMP has shared subscription for this mechanism.

### Fan-out

Fan-out: the message is broadcasted to all the consumers in the pool, and each consumer tune-in to the broadcast without affecting each other. JMS implement it with topic subscriptions, whereas AMQP has exchange bindings.

The above two techniques can be combined, in which multiple group of consumer nodes are there, and within each group only one consumer receives the message.

> **Diagram placeholder:** Load balancing and fan-out combined, with multiple consumer groups and one receiving consumer inside each group.

## Acknowledgments and Redelivery

To improve the reliability in consumer crash out scenarios, where the messages get dropped due to downtime at consumer node level, acknowledgments by consumer after completing the processing of a message, are used by message brokers. After the acknowledgment is received the message is removed from the queue.

It could happen that the message broker sends the message twice, if only the acknowledgment is lost, rather than the processing being disturbed, in such scenarios, an atomic protocol can be implemented.

When combined with load balancing, it can impact the order of messages after being processed. For example, we have two consumers: consumer1 and consumer2 in the pool and the initial message order is: m1,m2,m3,m4,m5. m1 and m3 goes to consumer2, whereas m2, m4, m5 goes to consumer1.

Let's say consumer2 crashes and m3 is not processed, and the redeliver causes the m3 to be delivered to consumer1, so at the end the order at which the messages will get consumer at consumer1 will be m4, m3, m5. It is not a problem if the messages are completely independent, but if there is a dependency in between messages it could cause fallacies.

> **Diagram placeholder:** Two load-balanced consumers processing m1 to m5, followed by consumer2 crashing and m3 being redelivered to consumer1 between m4 and m5.
