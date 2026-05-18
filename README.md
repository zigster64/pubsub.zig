# pubsub.zig

An embedded, type-safe, in-process pub/sub engine for Zig 0.16.

![Cyberpunk Zig PubSub Architecture](assets/pubsub.jpg)

- Topic routing driven by a tagged-union schema — the tag *is* the topic.
- Per-subscriber filters (`FilterId`) for broadcast or targeted delivery.
- Per-subscriber timeouts that inject `.timeout` events into the stream.
- Automatic deep-clone + refcount of payloads with allocated data.
- Built on `std.Io.Threaded`.

Used by the [Zig Datastar Webserver](https://github.com/zigster64/datastar.zig) for real-time collaborative web apps driven from the backend.

## Zig Version

Requires Zig 0.16

Ongoing experimental work happening in the 0.17 branch (adding fibers and coroutine support using vanilla stdlib as it evolves)

## Example

```zig
const std = @import("std");
const pubsub = @import("pubsub");

pub const MsgSchema = union(enum) {
    bat_signal: void,
};

const PS = pubsub.PubSub(MsgSchema);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    var ps = PS.init(io, gpa);
    defer ps.deinit();

    var mq = try ps.connect();
    defer mq.deinit();

    try mq.subscribe(.bat_signal);
    try ps.publish(.{ .bat_signal = {} }, .all);

    if (try mq.next()) |event| switch (event) {
        .msg => |m| { defer m.deinit(gpa); std.debug.print("got bat signal\n", .{}); },
        .timeout => {},
    };
}
```

A full producer/consumer demo lives in [`src/demo_threads.zig`](src/demo_threads.zig).

## Table of Contents

* [Installation](#installation)
* [Schema](#schema)
* [Creating a PubSub Engine](#creating-a-pubsub-engine)
* [Subscribing](#subscribing)
  * [Reading Messages](#reading-messages)
  * [Timeouts](#timeouts)
* [Publishing](#publishing)
* [Filters](#filters)
* [Engine Control](#engine-control)
* [Build, Run, Test](#build-run-test)
* [Roadmap](#roadmap)

## Installation

Fetch into your project:

```sh
zig fetch --save git+https://github.com/zigster64/pubsub.zig
```

In your `build.zig`:

```zig
const pubsub_dep = b.dependency("pubsub", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("pubsub", pubsub_dep.module("pubsub"));
```

In your code:

```zig
const pubsub = @import("pubsub");
const PubSub = pubsub.PubSub;
const FilterId = pubsub.FilterId;
```

## Schema

The engine carries structured messages defined as a **tagged union**. The tag is the topic, the payload is whatever struct/enum/void you attach.

```zig
pub const MsgSchema = union(enum) {
    cats: struct { id: u32, name: []const u8 },
    prices: struct { currency: []const u8, value: u64 },
    system_status: enum { starting, stopping, err },
    bat_signal: void,

    // Optional: deep-clone for payloads that own allocated memory.
    // The engine reflects for this and calls it before fanout.
    pub fn clone(self: MsgSchema, arena: Allocator) !MsgSchema {
        switch (self) {
            .cats => |c| return .{ .cats = .{
                .id = c.id,
                .name = try arena.dupe(u8, c.name),
            } },
            .prices => |p| return .{ .prices = .{
                .currency = try arena.dupe(u8, p.currency),
                .value = p.value,
            } },
            .bat_signal => return .{ .bat_signal = {} },
            .system_status => |s| return .{ .system_status = s },
        }
    }
};
```

If no variant owns allocated memory, skip `clone` entirely — the engine is zero-copy in that case:

```zig
pub const MsgSchema = union(enum) {
    bat_signal: void,
    cat_signal: void,
    dog_signal: void,
};
```

## Creating a PubSub Engine

`PubSub(Schema)` returns a type. `init(io, allocator)` constructs an instance.

```zig
const PS = pubsub.PubSub(MsgSchema);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    var ps = PS.init(io, gpa);
    defer ps.deinit();

    // spawn whatever producers and consumers you need
    var f_producer = try std.Io.concurrent(io, producer, .{ &ps });
    var f_consumer = try std.Io.concurrent(io, consumer, .{ &ps });

    try f_producer.await(io);
    try f_consumer.await(io);
}
```

## Subscribing

`ps.connect()` returns a `Subscriber` with its own inbound queue. Call `subscribe(.topic)` for each topic you want, then loop on `mq.next()`.

```zig
fn consumer(ps: *PS) !void {
    var mq = try ps.connect();
    defer mq.deinit();

    try mq.subscribe(.cats);
    try mq.subscribe(.prices);
    try mq.subscribe(.system_status);

    while (try mq.next()) |event| switch (event) {
        .msg => |m| {
            defer m.deinit(gpa);
            switch (m.topic) {
                .cats => std.debug.print("Cat: {s} ({d})\n", .{ m.payload.cats.name, m.payload.cats.id }),
                .prices => std.debug.print("Price: {d} {s}\n", .{ m.payload.prices.value, m.payload.prices.currency }),
                .system_status => switch (m.payload.system_status) {
                    .starting => std.debug.print("🟢 STARTING\n", .{}),
                    .stopping => std.debug.print("🔴 STOPPING\n", .{}),
                    .err => std.debug.print("⚠️ ERROR\n", .{}),
                },
                else => {},
            }
        },
        .timeout => {
            // optional heartbeat / housekeeping
        },
    };
}
```

### Reading Messages

`mq.next()` returns `!?Event`:

- `error` — read failed.
- `null` — engine has shut down. Treat as EOF.
- `.msg` — `m.payload` is your tagged union, `m.topic` is its tag, `m.filter_id` is the publish-time FilterId.
- `.timeout` — only emitted when a timeout is configured (see below).

`m.deinit(allocator)` releases the refcount for cloned payloads. The next call to `next()` will release any prior message automatically if you forget, but explicit `defer m.deinit(gpa)` is the safe habit.

### Timeouts

```zig
mq.setTimeout(.fromSeconds(2));                   // every next() injects .timeout after 2s of silence
mq.clearTimeout();                                // stop injecting timeouts
_ = try mq.nextTimeout(.fromMilliseconds(500));   // one-shot per-call timeout
```

All timeout APIs take an `std.Io.Duration` — use `.fromSeconds`, `.fromMilliseconds`, or `.fromNanoseconds`.

## Publishing

`publish(payload, filter_id)` fans the message out to every matching subscriber.

```zig
fn producer(ps: *PS) !void {
    try ps.publish(.{ .system_status = .starting }, .all);
    try ps.publish(.{ .cats = .{ .id = 1, .name = "Felix" } }, .all);
    try ps.publish(.{ .prices = .{ .currency = "USD", .value = 150 } }, .all);
    try ps.publish(.{ .bat_signal = {} }, .all);
    try ps.publish(.{ .system_status = .stopping }, .all);
}
```

If the payload has a `clone()` method, the engine deep-clones it into a refcounted envelope before fanout, then releases when every subscriber has consumed it.

## Filters

A `FilterId` is a non-exhaustive enum (backed by `u128`) for targeting a subset of subscribers within a topic. Picture a game server with thousands of concurrent games — every player only wants the messages for their game.

`.all` is the broadcast value; anything else is a targeted ID:

```zig
const id_from_uuid = FilterId.fromInt(0xBBBB_BBBB);
const id_from_str  = FilterId.fromSlice("game-1234");  // hashed to u128
```

A subscriber pins itself to one FilterId at a time. It will then receive only messages published with that same FilterId, plus `.all` broadcasts:

```zig
fn consumer(game_id: u128, ps: *PS) !void {
    var mq = try ps.connect();
    defer mq.deinit();

    mq.setFilter(FilterId.fromInt(game_id));

    try mq.subscribe(.move);
    try mq.subscribe(.clock);
    try mq.subscribe(.turn_end);

    mq.setTimeout(.fromSeconds(60));

    while (try mq.next()) |event| {
        // only msgs for this game (and .all broadcasts) arrive here
    }
}
```

Publishing with a specific filter only reaches subscribers pinned to it:

```zig
const game = FilterId.fromInt(123);

try ps.publish(.{ .move = {} }, game);       // only Game 123's players
try ps.publish(.{ .turn_end = {} }, game);   // only Game 123's players
try ps.publish(.{ .clock = {} }, .all);      // every player on every game
```

## Engine Control

```zig
ps.pause();           // stop accepting publishes
ps.unpause();
ps.togglePause();
ps.sleep(.fromSeconds(5));   // pause for the given Io.Duration, then resume
ps.shutdown();        // signal every subscriber; their next() returns null

const paused  = ps.isPaused();
const running = ps.isRunning();
```

## Build, Run, Test

```sh
zig build                 # build everything
zig build demo_threads    # run the threaded producer/consumer demo
zig build test            # run the test suite
```

## Roadmap

- Optional network transport so multiple processes can share a bus with the same client API. Publishes will fan out across peer services; `connect()` / `next()` semantics stay identical whether the engine is local or remote.
