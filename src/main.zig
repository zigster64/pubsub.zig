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
        .pubsub = PubSub(AppPayload).init(allocator),
        .running = std.atomic.Value(bool).init(true),
    };
    defer app.pubsub.deinit();

    var f_producer = try std.Io.concurrent(io, producer, .{&app});
    var f_consumer1 = try std.Io.concurrent(io, consumer, .{ &app, 1 });
    var f_consumer2 = try std.Io.concurrent(io, consumer, .{ &app, 2 });
    var f_consumer3 = try std.Io.concurrent(io, consumer, .{ &app, 3 });

    try std.Io.sleep(app.io, .fromSeconds(2), .real);
    app.running.store(false, .monotonic);

    try f_producer.await(io);
    try f_consumer1.await(io);
    try f_consumer2.await(io);
    try f_consumer3.await(io);
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

fn producer(ctx: *App) !void {
    var id_counter: u32 = 0;
    while (ctx.isRunning()) {
        id_counter += 1;
        {
            var buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "Cat_{d}", .{id_counter});
            std.debug.print("[PROD] Publishing {s}\n", .{name});
            try ctx.pubsub.publish(.{ .cats = .{ .id = id_counter, .name = name } });
        }
        try std.Io.sleep(ctx.io, .fromMilliseconds(500), .real);
    }
}

fn consumer(ctx: *App, id: u32) !void {
    var mq = try ctx.pubsub.subscriber();
    defer mq.deinit();

    try mq.subscribe(.cats);
    mq.setTimeout(2 * std.time.ns_per_s);

    std.debug.print("[CONS {d}] Started\n", .{id});

    while (ctx.isRunning()) {
        switch (mq.next()) {
            .msg => |m| {
                defer m.deinit(ctx.allocator);
                std.debug.print("  -> [CONS {d}] Got Cat: {s}\n", .{ id, m.payload.cats.name });
            },
            .timeout => {},
            .err => |e| {
                std.debug.print("Error: {}\n", .{e});
                break;
            },
            .quit => break,
        }
    }
}
