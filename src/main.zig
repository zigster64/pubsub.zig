const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;

const Verb = enum { subscribe, drop, publish, unknown };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    // Configuration
    const address = try std.Io.net.IpAddress.parseIp6("::", 9000);
    var server = try address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 1024,
    });
    defer server.deinit(io);

    var service = PubSubService.init(io, allocator);
    defer service.deinit();

    std.debug.print("PubSub Service listening on {}\n", .{address});

    while (true) {
        const conn = try server.accept(io);
        // In a real app, spawn a thread or use an event loop (kqueue/epoll)
        // For 40k subs, you'll want an async event loop.
        try service.handleConnection(conn);
    }
}

const PubSubService = struct {
    io: std.Io,
    allocator: Allocator,
    // Maps Topic Name -> List of Subscriber FDs
    topics: std.StringHashMap(std.ArrayList(posix.socket_t)),
    // Maps Socket FD -> List of Topics (for easy cleanup on 'drop')
    subs: std.AutoHashMap(posix.socket_t, std.ArrayList([]const u8)),

    fn init(io: std.Io, allocator: Allocator) PubSubService {
        return .{
            .io = io,
            .allocator = allocator,
            .topics = std.StringHashMap(std.ArrayList(posix.socket_t)).init(allocator),
            .subs = std.AutoHashMap(posix.socket_t, std.ArrayList([]const u8)).init(allocator),
        };
    }

    fn deinit(self: *PubSubService) void {
        var it = self.topics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.topics.deinit();

        var sit = self.subs.iterator();
        while (sit.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.subs.deinit();
    }

    fn handleConnection(self: *PubSubService, conn: std.Io.net.Stream) !void {
        var read_buf: [1024]u8 = undefined;
        var r = conn.reader(self.io, &read_buf);

        var buf: [1024]u8 = undefined;
        const n = try r.interface.readSliceAll(&buf);

        const line = mem.trimRight(u8, buf[0..n], "\n");
        var it = mem.tokenizeAny(u8, line, ": ");

        const verb_str = it.next() orelse return;
        const verb = std.meta.stringToEnum(Verb, verb_str) orelse .unknown;

        switch (verb) {
            .subscribe => {
                const id_str = it.next() orelse return; // In this version, we use FD as ID
                const topic = it.next() orelse return;
                try self.subscribe(conn.stream.handle, topic);
                std.debug.print("Subscribed {s} to {s}\n", .{ id_str, topic });
            },
            .publish => {
                const topic = it.next() orelse return;
                const data = it.rest();
                try self.broadcast(topic, data);
            },
            .drop => {
                try self.drop(conn.stream.handle);
            },
            else => {},
        }
    }

    fn subscribe(self: *PubSubService, fd: posix.socket_t, topic: []const u8) !void {
        // Add to topics map
        var res = try self.topics.getOrPut(topic);
        if (!res.found_existing) {
            res.key_ptr.* = try self.allocator.dupe(u8, topic);
            res.value_ptr.* = std.ArrayList(posix.socket_t).init(self.allocator);
        }
        try res.value_ptr.append(fd);

        // Add to reverse lookup for cleanup
        var sub_res = try self.subs.getOrPut(fd);
        if (!sub_res.found_existing) {
            sub_res.value_ptr.* = std.ArrayList([]const u8).init(self.allocator);
        }
        try sub_res.value_ptr.append(res.key_ptr.*);
    }

    fn broadcast(self: *PubSubService, topic: []const u8, data: []const u8) !void {
        if (self.topics.get(topic)) |subscribers| {
            for (subscribers.items) |fd| {
                const stream = std.Io.net.Stream{ .handle = fd };
                _ = stream.write(data) catch |err| {
                    std.debug.print("Failed to write to {}: {}\n", .{ fd, err });
                };
            }
        }
    }

    fn drop(self: *PubSubService, fd: posix.socket_t) !void {
        if (self.subs.fetchRemove(fd)) |entry| {
            var topics_list = entry.value;
            defer topics_list.deinit();

            for (topics_list.items) |t| {
                if (self.topics.getPtr(t)) |list| {
                    for (list.items, 0..) |item_fd, i| {
                        if (item_fd == fd) {
                            _ = list.swapRemove(i);
                            break;
                        }
                    }
                }
            }
        }
        posix.close(fd);
    }
};
