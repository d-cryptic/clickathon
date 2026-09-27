# Immutable Events, CQRS, and Concurrency

## Deriving multiple views while managing consistency and deletion

## Advantages of Immutable Events

Immutability in database is an old idea. Accountants have been using it in financial bookeeping in which a log of transactions is maintained. The catch here is the incorrect transactions are not removed from the log, in fact a correction transaction is added in the end, the incorrect transaction is not removed as it holds importance for auditing purpose.

The profit or loss is calculated by processing all the transaction in the end. This concepts is importance beyond financial world.

For example, in an shopping cart a customer adds an item and removed it, at database level this event would be deleted but not in the change log, the events holds importance in analytic purpose like what would be the chance that the user might add it again.

With an append only event log of immutable events, it is much easier to see what happened and recover.

## Deriving Several Views from the Same Event Log

By separating immutable event log and mutable state you can derive different read-oriented representations from the same log of events.

Having an explicit translation step from an event log to database makes it is easier to evolve your application over time, you can build a separate read optimized view by presenting your data in a different way. Whereas we all know it would be quite complicated to do a schema migration.

Storing data is straightforward, removes a lot of complexities of schema design and access patterns. The concept of separating the form in which data is written from the form in, by having several read views is known as Command Query Responsibility Segregation or CQRS.

The traditional approach of schema design by denormalizing data becomes irrelevant once you can translate data from write optimized event log to read optimized application state. Whereas once you have a read optimized view, denormalization can applied on it.

> **Diagram placeholder:** One write-optimized immutable event log feeding several read-optimized views for different application access patterns.

## Concurrency Control

The consumers of CDC or event sourcing are asynchronous, which mean a situation can occur when a write done to the event log is not yet reflected to the a view, and hence the user don't see their written data on the view.

To solve this issue, the mechanism that writes to the event log and the one that updates/constructs the views need to be in an atomic unit. Either you can combine this in a single transaction or keep of these components in a single data storage.

How you design of your system of events can also help dealing or removing the need of concurrency as well. You can design events such that they are self description of user action, so the user action requires the update to be done on a single place - an append only log.

If the event log and the application state are partitioned in the same way in concurrent system, then any action could be considered in a single transaction as an atomic unit. The ordering removes the non-determinism of the concurrency here.

## Immutability and Deletion

Many systems that don’t use an event-sourced model rely on immutability , like using immutable data structures to query snapshots of a database.

With storage becoming affordable, it is now possible for applications to store data history for long. But in some scenarios, deletion of data after certain time period is a necessity like government regulations for PII (Personal Identification Information).

It's quite hard to delete data entirely as copies of it can be in a lot of storage systems like SSDs, caches etc. So Deletion, in this scenario would be making it extremely hard to retrieve a particular information rather than removing it all.
