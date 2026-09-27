# Keeping Systems in Sync with Change Data Capture

## From inconsistent dual writes to ordered change streams

## Databases and Streams

We have seen how log based message brokers have taken ideas from databases, in this section we will look into the problem that occur in heterogeneous data systems and how streams can be efficient to solve them.

## Keeping Systems in Sync

Production scale applications usually have multiple data storages as per the application needs, for example, on OLTP database for user requests, a cache for common searches, index to handle search queries, a data warehouse for analytics.

Each of these data storage have their own representation, which is optimized for their use. As data is there in different places, they need to be in sync, meaning, a update or change in the database need to be replicated in all data storages used.

In case periodic full database dumps are too slow, dual writes, is an approach which is used, in which an application code is written to explicitly write to each of these data systems in case of data change.

Dual writes can make the application eco-system in consistent with race conditions, in the below representation, an update to value of X is triggered to A by client 1 and then to B by client 2, in the middle time, the database will show the value of X to be A whereas the search index is pointing to B, hence your system is at an inconsistent state.

> **Editable diagram:** [How concurrent dual writes leave the database with X=A and the search index with X=B](assets/dual-writes-race-condition.drawio).

Another problem with dual writes, is the possibility of any of the write to the data storage could fail on the network, for which your application (with its components) should be fault tolerant.

Even if your data storage systems have a leader - follower set-up, the leader for all data storages are different, which means that there would be still a scope for inconsistency in your application. It is ideal to have single leader for all the data storages, we will discuss the possibility of this approach in next section.

## Change Data Capture

Earlier in the days, the replication logs for a database were considered to be an internal part of the system, maintained through its data model and query language, not exposed as an API, due to which extracting the change and the order of the change to the database was difficult.

CDC (Change Data Capture) came into the picture, whose sole purpose was to observe and extract the data changes and replicate them to other systems. CDC could be made available as a stream, into which the producer data storage (database) could publish the data changes as they are written and the other components in the system like search index can consume them and the same order of log changes are applied then the data presented in all the data storage systems would be sme and bringing consistency to your application.

> **Editable diagram:** [How CDC keeps a cache, search index, and data warehouse synchronized through one ordered change stream](assets/cdc-sync-ecosystem.drawio).

## Implementing Change Data Capture

We can call the log consumers as derived data systems, as the data replicate to the consuming data storages are just another view on the data in the system of records. The database writing to the message broker becomes the leader and the ones consuming from the broker becomes the followers.

Since ordering of the events (a data change would be an event here) is important, a log based approach is ideal for this eco system. We can capture the trigger to the data changes and either add an entry to the changelog table (this could be slower and add to the operational overhead) or parse the replication logs (preferable as it is more robust).

With CDC you also have an operational advantage over slow consumers as the system is asynchronous, producers don’t wait for the consumers before writing to the message broker.

## Initial Snapshot

If you have the log of all changes that were ever made to the database, then you reconstruct the whole database from scratch, but with changes the change log becomes humongous and can eat up your disk space, moreover, processing such huge logs can be also a time consuming process.

It is more efficient to rebuild a state in database with a snapshot, given that the offset of the snapshot matches the offset from where your position in the change log is. Some CDC integrate snapshot facility while some leave it as a manual operation.

## Log Compaction

The challenge of disk space usage with storage of log history can also be solved with log compaction. The storage engine periodically looks for log records with the same key, and the value pointing to the key is changes if a change event occurs, a special null value indicates the delete operation.

As long as the key is there the series of operations taken with respect to the key are stored, which will contribute to the construction of the database, here the disk space required depends upon the number of records in the database rather than the number of operations. In CDC every change has a primary key, and every update replaces the previous value, the aim to keep the most recent write for a particular key.

To reconstruct the database, you can start from offset 0 to the log compacted topic, and sequentially scan over the messages. This feature is supported in Apache Kafka.

Increasingly, databases are beginning to support change streams as a first-class inter- face. Kafka Connect [37] is an effort to integrate change data capture tools for a wide range of database systems with Kafka.
