# Time, Watermarks, and Windows in Stream Processing

## Event time, processing time, stragglers, clocks, and window types

## Reasoning About Time

As we discussed that the analytical stream processors work a lot on "time window", but the understanding of window is not that straightforward.

Majorly stream processors use local system clock on the processing machine, to determine window, but with stream processors working at scale, the calculation of processing time becomes complicated.

For example, in case of significant lag due to some sub-system downtime, what time is to be considered, the time zone in which the sub-system is deployed in or the one that you have been considering so far.

## Event Time Versus Processing Time

There could be many reasons that could cause a processing delay: re-processing of messages, recovering from bugs, network failures, restart of a consumer.

Message delays could also lead to unpredictable ordering of messages, for example, if a user sends two request : A and B, B has a pre-requisite for A to be processed first, and the A request is handled by a separate web server than B, then it could happen that the request B reaches the server before A could, hence the processing of this request would be invalid, as the request B could not be processed before A.

Confusing processing time and failure can also lead to bad data. For example, a stream processor whose job is to measure the number of request that a server receive per window defined at the application level, due to some issues, if the stream processor is being restarted, so from the moment of it being down to being back online, the metrics would show a dip in the number of requests received whereas in reality the requests were coming at a steady rate.

> **Diagram placeholder:** Requests arriving at a steady rate in event time while a stream processor restart creates a false dip when measured by processing time.

## Knowing When You're Ready

The definition of windows, and to mark the start and the end of the window to consider event count in to the system has been a tricky task.

Marking of end of a window and the start of the next window, depends upon the question that have we processed all the events that have entered into the system in this time only.

One possible scenario, could be that the event of that particular window is in the system but is stuck in some other process due to some network failures, these kind of buffered events are know as straggler events.

The kind of events will turn up later, and it has to be decided how you will accumulate these events, there are two options:

1. The straggler events can be ignored, as under normal circumstances, these will be very small in number, as these grow in number, alerting mechanism can be set-up to notify if there's a underlying fault.

2. Issue a correction, and recalculate the value for the window with the stragglers included, then the adjusted value can be published.

One more possible way is to use a "low watermark" indicating the consumers, that there will be no more events that will come with a timestamp earlier than t, but it does not completely eradicate the occurrence of stragglers.

> **Diagram placeholder:** A time window closing at a low watermark, followed by a straggler event arriving late and either being ignored or causing a corrected result.

## Whose Clock Are You Using, Anyway?

Having timestamps to events is even more difficult for such applications where the events are buffered at several points in the system.

For example, a mobile application to track events. The events could be coming at regular time intervals, but the mobile got go offline, and in such cases the events will be available once the application is back up.

In this case, what should we consider for the metric purpose, ideally mobile's clock make sense, but it could be deliberately set wrong by the user. The server's clock makes more sense, but in the context of the application feature it's not relatable.

To adjust for incorrect device clocks, these three timestamps can be logged:

1. Device clock: The time at which the event occurred.

2. The POV of device clock: the time at which the event was sent to the system

3. Server clock: the time at which the event was received by the server

This approach help us to accommodate the offset between the device clock and the server clock to calculate the true time when the event occurred, assuming that the network lag in the ecosystem is negligible.

## Types of Window

Once the timestamp has been finalized, the next step is to define the windows over the time periods. The windows defined will be used for aggregation, count of events, maximum time duration of an event in a window.

Following are the types of window commonly used:

### 1. Tumbling Window

A tumbling window has fixed length, for example, a system having one minute window, will consider events from 10:03:00 to 10:03:59 in a single window. Rounding to the nearest timestamp is also used.

### 2. Hopping Window

A hopping window is a fixed window with some overlap to allow smoothing. For example, for a 5 minute hopping window, if the current window spans from 10:03:00 to 10:07:59, then then next window will cover the timestamp 10:04:00 to 10:08:59.

### 3. Sliding Window

A sliding window contains all the events that occur within some interval of each other. For example, for a 5 minute sliding window, events at 10:03:39 and 10:08:12 are considered in a single window, as they are less than 5 minutes apart.

This window can be implemented by keeping a buffer of events sorted by time, and removing old events when they expire from the window (starting form the earliest timestamp)

### 4. Session Window

This kind of window does not have a fixed duration, instead, it is defined by grouping together all events for the same user that occur together or close in time, the window ends when has been inactive for some time.

> **Diagram placeholder:** Tumbling, hopping, sliding, and session windows shown on the same event timeline.
