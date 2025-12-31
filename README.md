# Embedded PubSub Engine for Zig 0.16

![Cyberpunk Zig PubSub Architecture](assets/pubsub.jpg)

This repo is just a test jig for setting up a PubSub service for use in Zig 0.16
with an example producer/consumer and broadcast pattern

This code is currently limited to `std.Io.Threaded` ... in theory it should also 
work with `std.Io.Evented` coroutines, but we are not there yet with stdlib.

If you want to see this in more action, checkout the Datastar Zig SDK

https://github.com/zigster64/datastar.zig

Which uses this pubSub code to build real-time collaborative web apps - all from the backend, all in Zig

## Create a Payload definition schema

The PubSub system transmits structured messages to consumers via a queue.

You need to define a strict schema that covers all the different types of messages ... but luckily
you just define this schema as Zig structs

Then wrap each struct in a tagged union

Example - in this app, we have messages for Cats, Prices, and SystemStatus messages only

... and a BatSignal too !!!

```zig
pub const MsgSchema = union(enum) {
    cats: struct { id: u32, name: []const u8 },
    prices: struct { currency: []const u8, value: u64 },
    system_status: enum { starting, stopping, err },
    bat_signal: void, // just a signal with no data attached

    // Optionally add clone function if your data is complicated to deep copy.
    // the pubsub engine will reflect for this, and call it when it needs to clone data
    pub fn clone(self: MsgSchema, arena: Allocator) !MsgSchema {
        switch (self) {
            .cats => |c| return MsgSchema{
                .cats = .{
                    .id = c.id,
                    .name = try arena.dupe(u8, c.name),
                },
            },
            .prices => |p| return MsgSchema{
                .prices = .{
                    .currency = try arena.dupe(u8, p.currency),
                    .value = p.value,
                },
            },
            .bat_signal => return MsgSchema{ .bat_signal = {} },
            .system_status => |s| return MsgSchema{ .system_status = s },
        }
    }
};
```

That covers every possible thing, but may be overkill for your application

If you just want a handful of topics with no associated data, this works fine too, 
and is zero-copy within the pub sub engine.

```zig
pub const MsgSchema = union(enum) {
    bat_signal: void, // just a signal with no data attached
    cat_signal: void,
    dog_signal: void,

    // dont even need a clone function
}
```

## Create a PubSub based off a schema

Create an instance of a PubSub engine using the given messaging schema

```zig

const PUB_SUB = PubSub(MsgSchema); // a type

pub fn main() !void {
    const smp = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init(smp);
    defer threaded.deinit();
    const io = threaded.io();

    var pubsub = PUB_SUB.init(io, smp); // <-- use the MsgSchema here
    defer pubsub.deinit();

    ...

    // launch the consumer and producer
    try Io.concurrent(io, consumer, { &pubsub });
    try Io.concurrent(io, producer, { &pubsub });

    ...
}
```

## Connect to the PubSub object as a subscriber

Write a long running function that connects to the PubSub engine, 
subscribes to topics, then runs a loop reading messages till done

```zig
fn consumer(pubsub: *PUB_SUB) !void {
    // connect to the engine
    var mq = try pubsub.connect();

    // deinit will unsubscribe, clean up, etc
    defer mq.deinit();

    // Subscribe to everything we care about
    try mq.subscribe(.cats);
    try mq.subscribe(.prices);
    try mq.subscribe(.system_status);

    // optionally set a timeout - will generate .timeout messages if you do
    mq.setTimeout(2 * std.time.ns_per_s);

    std.debug.print("Consumer Started\n", .{id});

    // mq.next() will block and wait for a new message
    // When it gets one, it will return an event of type MsgSchema
    // if you get a valid value, the check if its a .msg or .timeout
    // if its a .msg, switch on the m.topic to decode the tagged enum type
    //   - the m.payload.ENUM contains the decoded payload
    // if its a timeout, it received no msg by the timeout time - do housekeeping
    // if the pubsub service is finished, no more msgs will arrive, so mq.next() returns NULL
    // if there was an error, mq.next() returns an error
    while (try mq.next()) |event| {
        switch (event) {
            .msg => |m| {
                switch (m.topic) {
                    .cats => {
                        std.debug.print("  -> [CONSUMER] Cat: {s} (ID: {d})\n", .{ id, m.payload.cats.name, m.payload.cats.id });
                    },
                    .prices => {
                        // Accessing .prices payload safely
                        const p = m.payload.prices;
                        std.debug.print("  -> [CONSUMER] Market Update: {d} {s}\n", .{ id, p.value, p.currency });
                    },
                    .system_status => {
                        // Enum switching for system status
                        switch (m.payload.system_status) {
                            .starting => std.debug.print("  -> [CONSUMER] 🟢 SYSTEM STARTING\n", .{id}),
                            .stopping => std.debug.print("  -> [CONSUMER] 🔴 SYSTEM STOPPING\n", .{id}),
                            .err => std.debug.print("  -> [CONSUMER] ⚠️ SYSTEM ERROR\n", .{id}),
                        }
                    },
                    else => {},
                }
            },
            .timeout => {
                // Heartbeat logic could go here
                std.debug.print("  -> [CONSUMER] ⏰ 2s TIMEOUT reading Msg Queue\n", .{id});
            },
        }
    }
}
```

## Publish to a topic

From anywhere else in your code (including other threads), you can publish to topics 

```zig
fn producer(pubsub: *PUB_SUB) !void {
    // Send a 'Starting' signal immediately to all subscribers
    try pubsub.publish(.{ .system_status = .starting }, .all);

    // Publish a Cat message, that includes a cat struct
    // The pubsub engine will deep clone the data, and then use a RefCount 
    // to track when everyone has read it, then free it
    const name = try std.fmt.bufPrint(&buf, "Cat_{d}", .{id_counter});
    try pubsub.publish(.{ .cats = .{ .id = id_counter, .name = name } }, .all);

    // Publish Price
    // Again the data is deep cloned, RefCounted, then freed inside the engine
    try pubsub.publish(.{ .prices = .{ .currency = "USD", .value = id_counter * 150 } }, .all);

    // Simulate Error
    try pubsub.publish(.{ .system_status = .err }, .all);

    // Issue the bat signal
    // Note the use of `= {}` to set a void value
    // ... bit annoying to type every time, but at least its clear what its doing here
    try pubsub.publish(.{ .bat_signal = {} }, .all);

    // Send 'Stopping' signal before exit
    try pubsub.publish(.{ .system_status = .stopping }, .all);
}
```

# Apply Filters to subscriptions

You can set a FilterID on a pubsub client if you are only interested events related
to some ID.  (eg - think GameID with unlimited games, and a limited set of events for any 1 game)

A FilterID is non-exhaustive enum that includes

- .all for broadcast to all subscribers
- a UUID / u128 value that uniquely identifies the filter within that channel

Then, all subscriptions that you listen on with this client, you will only 
receive the broadcasts on all those topics that include the FilterIO

Use Case :  Consider an online game, where you have say - 1000 games in progress,
each with a handful of players.

During the course of play, you may want to broadcast messages on the topics
- .move
- .clock
- .turn_end
- .game_over
- .event

But on each of these broadcasts, include the GameID (UUID), so it only gets sent to
the handful of players subscribed to this GameID.

Here is how to do that :

```zig
fn consumer(game: GAME, p: PUB_SUB) void {
    var mq = try p.connect();
    defer mq.deinit();

    // Set a filter saying we only want to receive messages
    // related to the Game we are playing - not all 1000 games
    try mq.setFilter(.from(game.ID));

    // Subscribe to everything we care about
    try mq.subscribe(.move);
    try mq.subscribe(.clock);
    try mq.subscribe(.turn_end);
    try mq.subscribe(.game_over);
    try mq.subscribe(.event);

    // if no messages for 60 seconds, do some keepalive housekeeping
    try mq.setTimeout(60 * std.time.ns_per_s);

    while (try mq.next()) |event| {
        ... process all the events
        ... we will only get msg events related to game.ID
        ... or still get a .timeout if nothing at all for a 60 seconds
    }
}
```

Then when publishing a message, use the last parameter to set the FilterID.

```zig
    // from the previous example we did this with .all to broadcast to all
    try pubsub.publish(.{ .bat_signal = {} }, .all);

    // now broadcast move and turn_end updates to any players listening on Game 123
    try pubsub.publish(.{ .move = {} }, 123);
    try pubsub.publish(.{ .turn_end = {} }, 123);
    // then broadcast a game clock update to every player on every game
    try pubsub.publish(.{ .clock = {} }, .all);
```

# Engine Control

There are a few helper functions that you can use to control the PubSub engine while its running

```zig
pubsub.pause();
pubsub.unpause();
pubsub.togglePause();
pubsub.sleep(Duration);
pubsub.shutdown();
```
These functions can be used to pause / awaken / stop the engine.

You can call `sleep(Duration)` to put the engine on pause for the given duration

You can call
```zig
pubsub.isPaused() bool;
pubsub.isRunning() bool;
```
To read the current state.

# TODO 

The above functions are all I need for now to finish off the embedded PubSub that I need now for
another project.

But there is more that I will need after that, so will be adding the following features :

- Wrap the whole lib in a network interface, so you can run a standalone PubSub service and have
multiple services connecting to it. 
- The API in the app will be identical to the embedded API - just an extra set of options on the 
pubsub.init() function to say whether its local/embedded, or somewhere over the network.
- Client API will be the same - just call pubsub.connect() to get an mq that you can mq.next() on. 
The fact that its over the network will be transparent.
- The networked version will, of course, enable publish() results to fan out across all peer services.

Its not entirely hard to do, but still a lot of work to get right.


