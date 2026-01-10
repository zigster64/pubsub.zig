const std = @import("std");
const testing = std.testing;
const PubSubModule = @import("pubsub.zig");
const FilterId = PubSubModule.FilterId;

// Access the real Io type from the environment
const Io = std.Io;

// -------------------------------------------------------------------------
// 1. TEST PAYLOAD
// -------------------------------------------------------------------------
const TestSchema = union(enum) {
    ping: void,
    data: struct { id: u32, content: []const u8 },
    secret: void,

    pub fn needsClone(self: TestSchema) bool {
        return switch (self) {
            .ping, .secret => false,
            .data => true,
        };
    }

    pub fn clone(self: TestSchema, arena: std.mem.Allocator) !TestSchema {
        switch (self) {
            .ping => return .{ .ping = {} },
            .secret => return .{ .secret = {} },
            .data => |d| return .{ .data = .{
                .id = d.id,
                .content = try arena.dupe(u8, d.content),
            } },
        }
    }
};

const PS = PubSubModule.PubSub(TestSchema);

// -------------------------------------------------------------------------
// 2. UNIT TESTS
// -------------------------------------------------------------------------

test "PubSub: Basic Signal (Zero Alloc)" {
    const allocator = testing.allocator;

    // Use Real IO
    var threaded = Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var pubsub = PS.init(io, allocator);
    defer pubsub.deinit();

    var sub = try pubsub.connect();
    defer sub.deinit();

    try sub.subscribe(.ping);

    try pubsub.publish(.{ .ping = {} }, .all);

    const event = (try sub.next()) orelse return error.NullEvent;
    switch (event) {
        .msg => |m| {
            defer m.deinit(allocator);
            try testing.expectEqual(std.meta.Tag(TestSchema).ping, m.topic);
        },
        else => return error.WrongEventType,
    }
}

test "PubSub: Complex Data (Reference Counting)" {
    const allocator = testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var pubsub = PS.init(io, allocator);
    defer pubsub.deinit();

    var sub1 = try pubsub.connect();
    defer sub1.deinit();
    try sub1.subscribe(.data);

    var sub2 = try pubsub.connect();
    defer sub2.deinit();
    try sub2.subscribe(.data);

    const text = "Hello Reference Counting";
    try pubsub.publish(.{ .data = .{ .id = 42, .content = text } }, .all);

    // Consumer 1 verifies
    {
        const event = (try sub1.next()) orelse return error.NullEvent;
        switch (event) {
            .msg => |m| {
                defer m.deinit(allocator);
                try testing.expectEqual(m.payload.data.id, 42);
                try testing.expectEqualStrings(m.payload.data.content, text);
            },
            else => return error.WrongEventType,
        }
    }

    // Consumer 2 verifies (Tests shared ownership)
    {
        const event = (try sub2.next()) orelse return error.NullEvent;
        switch (event) {
            .msg => |m| {
                defer m.deinit(allocator);
                try testing.expectEqualStrings(m.payload.data.content, text);
            },
            else => return error.WrongEventType,
        }
    }
}

test "PubSub: Filter Routing" {
    const allocator = testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var pubsub = PS.init(io, allocator);
    defer pubsub.deinit();

    const uuid_a = 0xAAAA_AAAA_AAAA_AAAA;
    const filter_a = FilterId.fromInt(uuid_a);

    var sub_a = try pubsub.connect();
    defer sub_a.deinit();
    try sub_a.subscribe(.ping);
    sub_a.setFilter(filter_a);

    var sub_b = try pubsub.connect();
    defer sub_b.deinit();
    try sub_b.subscribe(.ping);

    // 1. Broadcast -> Both
    try pubsub.publish(.{ .ping = {} }, .all);

    if ((try sub_a.next())) |e| {
        if (e == .msg) e.msg.deinit(allocator);
    } else return error.ExpectedMsgA;
    if ((try sub_b.next())) |e| {
        if (e == .msg) e.msg.deinit(allocator);
    } else return error.ExpectedMsgB;

    // 2. Targeted A -> only A gets it, B gets a timeout
    try pubsub.publish(.{ .ping = {} }, filter_a);

    sub_b.setTimeout(.fromMilliseconds(250));
    if ((try sub_a.next())) |e| {
        if (e == .msg) e.msg.deinit(allocator);
    } else return error.ExpectedMsgA_Targeted;
    if ((try sub_b.next())) |e| {
        switch (e) {
            .msg => |m| {
                m.deinit(allocator);
                return error.BShouldNotReceiveFiltered;
            },
            .timeout => {}, // thats what we want, because B never gets the message
        }
    } else return error.ExpectedMsgB_Targeted_ShouldGetTimeout;

    // 3. Targeted B -> A should NOT get it
    const filter_b = FilterId.fromInt(0xBBBB_BBBB);
    try pubsub.publish(.{ .ping = {} }, filter_b);

    sub_a.setTimeout(.fromMilliseconds(250));
    const res = try sub_a.next();
    if (res) |e| {
        switch (e) {
            .msg => |m| {
                m.deinit(allocator);
                return error.AShouldNotReceiveFiltered;
            },
            .timeout => {}, // thats what we want
        }
    }
}

// -------------------------------------------------------------------------
// 3. E2E CONCURRENCY TEST
// -------------------------------------------------------------------------

const E2EContext = struct {
    ps: *PS,
};

fn producer_thread(io: Io, ctx: *E2EContext) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        ctx.ps.publish(.{ .data = .{ .id = i, .content = "data" } }, .all) catch {};
        // Tiny sleep to yield
        std.Io.sleep(io, .fromNanoseconds(10_000), .real) catch {};
    }
    ctx.ps.publish(.{ .ping = {} }, .all) catch {};
}

test "PubSub: E2E Concurrent Producer/Consumer" {
    const allocator = testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var pubsub = PS.init(io, allocator);
    defer pubsub.deinit();

    var ctx = E2EContext{ .ps = &pubsub };

    // 1. SETUP CONSUMER FIRST (So we don't miss any messages)
    var sub = try pubsub.connect();
    defer sub.deinit();
    try sub.subscribe(.data);
    try sub.subscribe(.ping);

    // 2. NOW SPAWN PRODUCER
    var t_prod = try io.concurrent(producer_thread, .{ io, &ctx });
    defer t_prod.cancel(io);

    // 3. START CONSUMING
    var count: u32 = 0;
    while (true) {
        const event = (try sub.next()) orelse break;
        switch (event) {
            .msg => |m| {
                defer m.deinit(allocator);
                switch (m.topic) {
                    .data => count += 1,
                    .ping => break,
                    else => {},
                }
            },
            .timeout => {},
        }
    }

    // Now we should get exactly 100
    try testing.expectEqual(count, 100);
}

test "PubSub: E2E Concurrent Producer/Consumer out of order" {
    const allocator = testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    var pubsub = PS.init(io, allocator);
    defer pubsub.deinit();

    var ctx = E2EContext{ .ps = &pubsub };

    var t_prod = try io.concurrent(producer_thread, .{ io, &ctx });
    defer t_prod.cancel(io);

    // producer is pumping away - we defs going to miss the first few
    // if we dont, then there is something horribly out of whack with the threading
    // implementation

    var sub = try pubsub.connect();
    defer sub.deinit();
    try sub.subscribe(.data);
    try sub.subscribe(.ping);

    var count: u32 = 0;
    while (true) {
        const event = (try sub.next()) orelse break;
        switch (event) {
            .msg => |m| {
                defer m.deinit(allocator);
                switch (m.topic) {
                    .data => count += 1,
                    .ping => break,
                    else => {},
                }
            },
            .timeout => {},
        }
    }

    try testing.expect(count < 100);
}
