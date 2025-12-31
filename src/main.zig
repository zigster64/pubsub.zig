const std = @import("std");
const pubsub_module = @import("pubsub.zig");
const PubSub = pubsub_module.PubSub;

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var app = App{
        .allocator = allocator,
        .io = io,
        .pubsub = PubSub(AppPayload).init(io, allocator),
        .running = std.atomic.Value(bool).init(true),
    };
    defer app.pubsub.deinit();

    var f_producer1 = try std.Io.concurrent(io, producer, .{ &app, 200 });
    var f_consumer0 = try std.Io.concurrent(io, consumer, .{ &app, 0 });
    var f_consumer1 = try std.Io.concurrent(io, consumer, .{ &app, 1 });
    var f_consumer2 = try std.Io.concurrent(io, consumer, .{ &app, 2 });
    var f_consumer3 = try std.Io.concurrent(io, consumer, .{ &app, 3 });

    // wait 30 seconds and add another fast producer
    try std.Io.sleep(app.io, .fromSeconds(20), .real);
    std.debug.print("🚀 Turbo Producer Mode Initiating in 5s\n", .{});
    app.pubsub.sleep(.fromSeconds(5));
    var f_producer2 = try std.Io.concurrent(io, producer, .{ &app, 50 });

    try std.Io.sleep(app.io, .fromSeconds(20), .real);
    std.debug.print("😴 Pausing the whole pubsub system for 20s\n", .{});
    app.pubsub.sleep(.fromSeconds(20));

    try std.Io.sleep(app.io, .fromSeconds(20), .real);
    std.debug.print("🚀🚀🚀 Super Turbo Producer Mode Initiating in 5s\n", .{});
    app.pubsub.sleep(.fromSeconds(5));
    var f_producer3 = try std.Io.concurrent(io, producer, .{ &app, 5 });

    try std.Io.sleep(app.io, .fromSeconds(120), .real);

    app.running.store(false, .monotonic); // shut the whole thing down !

    try f_producer1.await(io);
    try f_consumer0.await(io);
    try f_consumer1.await(io);
    try f_consumer2.await(io);
    try f_consumer3.await(io);
    try f_producer2.await(io);
    try f_producer3.await(io);
}

// App Context and PubSub payload definitions
const App = struct {
    io: std.Io,
    allocator: Allocator,
    pubsub: PubSub(AppPayload),
    running: std.atomic.Value(bool),

    pub fn init(io: std.Io, allocator: std.mem.Allocator) App {
        return .{
            .io = io,
            .allocator = allocator,
            .pubsub = PubSub(AppPayload).init(allocator),
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn isRunning(app: *App) bool {
        return app.running.load(.monotonic);
    }

    pub fn setRunning(app: *App, value: bool) void {
        app.running.store(value, .monotonic);
    }
};

pub const AppPayload = union(enum) {
    cats: struct { id: u32, name: []const u8 },
    prices: struct { currency: []const u8, value: u64 },
    system_status: enum { starting, stopping, err },

    pub fn clone(self: AppPayload, arena: Allocator) !AppPayload {
        switch (self) {
            .cats => |c| return AppPayload{
                .cats = .{
                    .id = c.id,
                    .name = try arena.dupe(u8, c.name),
                },
            },
            .prices => |p| return AppPayload{
                .prices = .{
                    .currency = try arena.dupe(u8, p.currency),
                    .value = p.value,
                },
            },
            .system_status => |s| return AppPayload{ .system_status = s },
        }
    }
};

fn producer(ctx: *App, delay: i64) !void {
    var id_counter: u32 = 0;

    // Send a 'Starting' signal immediately
    try ctx.pubsub.publish(.{ .system_status = .starting });
    var buf: [64]u8 = undefined;

    while (ctx.isRunning()) {
        id_counter += 1;

        // 1. Publish Cat (Every tick)
        {
            const name = try std.fmt.bufPrint(&buf, "Cat_{d}", .{id_counter});
            try ctx.pubsub.publish(.{ .cats = .{ .id = id_counter, .name = name } });
        }

        // 2. Publish Price (Every 3rd tick)
        if (id_counter % 3 == 0) {
            try ctx.pubsub.publish(.{ .prices = .{ .currency = "USD", .value = id_counter * 150 } });
        }

        // 3. Simulate Error (Every 10th tick)
        if (delay > 100 and id_counter % 10 == 0) {
            try ctx.pubsub.publish(.{ .system_status = .err });

            // then sleep for 3 seconds, which will trigger timeouts on the consumers
            std.debug.print("[PROD] Sleep 3s\n", .{});
            try std.Io.sleep(ctx.io, .fromSeconds(3), .real);
        }

        try std.Io.sleep(ctx.io, .fromMilliseconds(delay), .real);
    }

    // Send 'Stopping' signal before exit
    try ctx.pubsub.publish(.{ .system_status = .stopping });
}

fn consumer(ctx: *App, id: u32) !void {
    var mq = try ctx.pubsub.client();
    defer mq.deinit();

    // 1. Subscribe to everything we care about
    if (id != 1) try mq.subscribe(.cats);
    if (id != 2) try mq.subscribe(.prices);
    if (id != 3) try mq.subscribe(.system_status);

    mq.setTimeout(2 * std.time.ns_per_s);

    std.debug.print("[CONS {d}] Started\n", .{id});

    while (ctx.isRunning()) {
        switch (mq.next()) {
            .msg => |m| {
                // Memory Safety: Ensure we release the ref-counted message
                defer m.deinit(ctx.allocator);

                switch (m.topic) {
                    .cats => {
                        std.debug.print("  -> [CONS {d}] Cat: {s} (ID: {d})\n", .{ id, m.payload.cats.name, m.payload.cats.id });
                    },
                    .prices => {
                        // Accessing .prices payload safely
                        const p = m.payload.prices;
                        std.debug.print("  -> [CONS {d}] Market Update: {d} {s}\n", .{ id, p.value, p.currency });
                    },
                    .system_status => {
                        // Enum switching for system status
                        switch (m.payload.system_status) {
                            .starting => std.debug.print("  -> [CONS {d}] 🟢 SYSTEM STARTING\n", .{id}),
                            .stopping => std.debug.print("  -> [CONS {d}] 🔴 SYSTEM STOPPING\n", .{id}),
                            .err => std.debug.print("  -> [CONS {d}] ⚠️ SYSTEM ERROR\n", .{id}),
                        }
                    },
                }
            },
            .timeout => {
                // Heartbeat logic could go here
                std.debug.print("  -> [CONS {d}] ⏰ 2s TIMEOUT reading Msg Queue\n", .{id});
            },
            .err => |e| {
                std.debug.print("Error: {}\n", .{e});
                break;
            },
            .quit => break,
        }
    }
}
