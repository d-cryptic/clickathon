# Event Sourcing, Commands, and Immutable Events

## Deriving the current state from a durable history of facts

## Event Sourcing

Event Sourcing works on the changes to the application state stored as a log of events. In case of CDC, where database is used in a mutable way, updating and deleting records at will. The replication log is parsed to make sure the order of writes are the same as they occur in reality, the application writing to the database does not need to be aware that the CDC is occurring.

On the other hand, in event sourcing the event log which is made of immutable events, meaning event log is append only, update or delete is strictly prohibited. Events are made to mirror the changes happening to the application state.

There are quite much similarities between event log and a fact table in the case of star schema. Any conventional database or log based message broker can be used for the purpose, Event Store, is an example.

## Deriving Current State from the Event Log

An end user of the application is more interested in seeing the current state of the system, rather than the change log that brought the system to the current state.

Hence, you need a deterministic approach, to process the log of change events and derive the current state of the system, before sending it to the user, deterministic because you can run the processes multiple times to end at the same state, everytime.

Like CDC, replaying the event log allows you to reconstruct the current state of the system. Since in CDC, in the case of log compaction, the current value of the primary key is determined by the most recent event (latest version of the record), previous records are ignored or deleted.

But in the case of event sourcing, events are modeled at a higher level, an event in this scenario, represents the intent of an user action, not the set of actions, or update events that let the system to this state, hence history of the events hold a significant value and can’t be discarded.

Log compaction is difficult in the case of event sourcing, a snapshot based approach is used in some application, to avoid, re-processing the full log store, but the requirement of history of events to be stored forever is still a criteria.

## Commands and Events

In the context of event sourcing it is very important to distinguish between a command and a event.

When a request from a user first arrives, it is a command, the action could be rejected or failed, depending upon the integrity checks made at the system level.

For example, for a user to create an account on your application, it is required that the username should be unique, hence this action could be rejected on the basis of the data given by the user. Once the validations passes, the command becomes an event, which immutable and durable.

Once a event is generated it becomes a fact. In a online flight ticket booking system, a user can cancel a booking, but that action also does not erase the fact that a reservation for a particular flight was made earlier by this user. The cancelation becomes a separate event in the change log.

A consumer can not reject any event, hence, any validation of command must happened synchronously, before it becomes an event, as a message broker will have multiple consumers, to avoid inconsistency.

## State, Streams and Immutability

The principle of immutability is what makes change data capture and event sourcing so powerful. But we all know that state changes, for example the current available seats is the result of all the reservations that your system has processed, the current balance of a bank account is the result of the credits and debits that have been made, the how does the concept of immutability fits here?

The key here is state is the result of the events that mutated it over time. No matter how state changes, there was always a sequence of events that made the state so.

Even though the operations are done or undone, the fact remains true that a particular event occurred. The mutable state and the append-only immutable log of events do not contradict with each other.

Analogy would say, application state is what you get when you integrate an event stream over time and a change stream is what you get when you differentiate the state by time.

> **Diagram placeholder:** An immutable event stream being integrated over time into mutable application state, and application state being differentiated into a change stream.
