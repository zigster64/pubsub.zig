const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const FilterId = enum(u128) {
    all = 0,
    _,
    pub fn from(uuid: u128) FilterId {
        return @enumFromInt(uuid);
    }
};

pub fn PubSub(comptime UserPayload: type) type {
    const Topic = std.meta.Tag(UserPayload);
    const TopicCount = std.meta.fields(Topic).len;

    return struct {
        const Self = @This();

        // --------------------------------------------------------
        // Internal Types
        // --------------------------------------------------------

        const RcEnvelope = struct {
            ref_count: std.atomic.Value(usize),
            arena: std.heap.ArenaAllocator,
            filter_id: FilterId,

            pub fn release(self: *@This(), parent_alloc: Allocator) void {
                if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
                    var arena = self.arena;
                    arena.deinit();
                    parent_alloc.destroy(self);
                }
            }
        };

        const QueueItem = struct {
            payload: UserPayload,
            envelope: ?*RcEnvelope,
        };

        const QueueNode = union(enum) {
            data: QueueItem,
            quit: void,
        };

        // --------------------------------------------------------
        // Public Types
        // --------------------------------------------------------

        pub const Message = struct {
            envelope: ?*RcEnvelope,
            payload: UserPayload,
            topic: Topic,
            filter_id: FilterId,
            subscriber: *Subscriber,

            pub fn deinit(self: @This(), allocator: Allocator) void {
                self.subscriber.manualRelease(self.envelope, allocator);
            }
        };

        pub const Event = union(enum) {
            msg: Message,
            timeout: void,

            pub fn format(
                self: Event,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt;
                _ = options;

                switch (self) {
                    .msg => |m| try writer.print("msg(topic: {any})", .{m.topic}),
                    .timeout => try writer.writeAll("timeout"),
                }
            }
        };

        pub const Subscriber = struct {
            allocator: Allocator,
            parent: *Self,
            queue: std.Deque(QueueNode),
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            subscriptions: std.ArrayList(Topic) = .empty,
            filter_id: std.atomic.Value(u128) = std.atomic.Value(u128).init(@intFromEnum(FilterId.all)),
            timeout_ns: ?u64 = null,
            active_envelope: ?*RcEnvelope = null,

            pub fn init(allocator: Allocator, parent: *Self) !Subscriber {
                return .{
                    .allocator = allocator,
                    .parent = parent,
                    .queue = try std.Deque(QueueNode).initCapacity(allocator, 1024),
                };
            }

            pub fn deinit(self: *Subscriber) void {
                // if the schema has only 1 entry then sizeof topic is 0
                if (@sizeOf(Topic) == 0) {
                    const count = self.subscriptions.items.len;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        // Since there's only one topic, index is always 0
                        self.parent.unsubscribeRaw(@enumFromInt(0), self);
                    }
                } else {
                    for (self.subscriptions.items) |topic| {
                        self.parent.unsubscribeRaw(topic, self);
                    }
                }

                if (self.active_envelope) |env| {
                    env.release(self.allocator);
                    self.active_envelope = null;
                }

                //    This prevents race conditions with Shutdown() calling sub.close()
                self.mutex.lock();
                while (self.queue.popFront()) |item| {
                    switch (item) {
                        .data => |d| if (d.envelope) |e| e.release(self.allocator),
                        else => {},
                    }
                }
                self.mutex.unlock(); // Unlock before destroying the queue

                if (@sizeOf(Topic) != 0) {
                    self.subscriptions.deinit(self.allocator);
                }
                self.queue.deinit(self.allocator);
            }

            pub fn manualRelease(self: *Subscriber, env_ptr: ?*RcEnvelope, alloc: Allocator) void {
                const e = env_ptr orelse return;
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.active_envelope == e) {
                    self.active_envelope = null;
                    e.release(alloc);
                }
            }

            pub fn close(self: *Subscriber) void {
                // Inject the special .quit signal locally
                self.push(.quit) catch {};
            }

            pub fn next(self: *Subscriber) !?Event {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.active_envelope) |env| {
                    env.release(self.allocator);
                    self.active_envelope = null;
                }

                while (self.queue.len == 0) {
                    if (self.timeout_ns) |ns| {
                        // TODO - this will probably change soon to std.Io.something
                        self.cond.timedWait(&self.mutex, ns) catch |err| {
                            if (err == error.Timeout) return .timeout;
                            return err;
                        };
                    } else {
                        self.cond.wait(&self.mutex);
                    }
                }

                const item = self.queue.popFront() orelse return error.UnexpectedEmpty;

                switch (item) {
                    .data => |d| {
                        if (d.envelope) |env| self.active_envelope = env;
                        return Event{ .msg = Message{
                            .envelope = d.envelope,
                            .payload = d.payload,
                            .topic = std.meta.activeTag(d.payload),
                            .filter_id = if (d.envelope) |e| e.filter_id else .all,
                            .subscriber = self,
                        } };
                    },
                    .quit => return null,
                }
            }

            pub fn nextPayload(self: *Subscriber) !?UserPayload {
                while (true) {
                    const event = (try self.next()) orelse return null;
                    switch (event) {
                        .msg => |m| {
                            defer m.deinit(self.allocator);
                            return m.payload;
                        },
                        .timeout => continue,
                    }
                }
            }

            pub fn setFilter(self: *Subscriber, id: FilterId) void {
                self.filter_id.store(@intFromEnum(id), .monotonic);
            }

            pub fn setTimeout(self: *Subscriber, ns: u64) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.timeout_ns = ns;
            }

            pub fn subscribe(self: *Subscriber, topic: Topic) !void {
                const index = @intFromEnum(topic);
                self.parent.locks[index].lock();
                defer self.parent.locks[index].unlock();
                try self.parent.registry[index].append(self.parent.allocator, self);

                // If the schema has only 1 entry, then sizeof schema is 0
                if (@sizeOf(Topic) == 0) {
                    self.subscriptions.items.len += 1;
                } else {
                    try self.subscriptions.append(self.allocator, topic);
                }
            }

            pub fn push(self: *Subscriber, item: QueueNode) !void {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.pushBack(self.allocator, item);
                self.cond.signal();
            }
        };

        // --------------------------------------------------------
        // Main Fields & Methods
        // --------------------------------------------------------

        io: Io,
        allocator: Allocator,
        registry: [TopicCount]std.ArrayList(*Subscriber) = undefined,
        locks: [TopicCount]std.Thread.RwLock = undefined,
        paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

        pub fn init(io: Io, allocator: Allocator) Self {
            var self = Self{ .io = io, .allocator = allocator };
            inline for (0..TopicCount) |i| {
                self.registry[i] = std.ArrayList(*Subscriber).empty;
                self.locks[i] = std.Thread.RwLock{};
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            inline for (0..TopicCount) |i| {
                self.registry[i].deinit(self.allocator);
            }
        }

        pub fn connect(self: *Self) !Subscriber {
            return Subscriber.init(self.allocator, self);
        }

        pub fn togglePause(self: *Self) void {
            _ = self.paused.swap(!self.paused.load(.acquire), .acq_rel);
        }

        pub fn sleep(self: *Self, delay: ?Io.Duration) void {
            self.paused.store(true, .monotonic);
            if (delay) |d| {
                self.io.sleep(d, .real) catch {};
                self.paused.store(false, .monotonic);
            }
        }

        pub fn pause(self: *Self) void {
            self.paused.store(true, .monotonic);
        }

        pub fn unpause(self: *Self) void {
            self.paused.store(false, .monotonic);
        }

        pub fn shutdown(self: *Self) void {
            self.paused.store(true, .seq_cst);
            self.running.store(false, .seq_cst);

            inline for (0..TopicCount) |i| {
                self.locks[i].lockShared();
                defer self.locks[i].unlockShared();

                for (self.registry[i].items) |sub| {
                    sub.close();
                }
            }
        }

        pub fn isPaused(self: *Self) bool {
            return self.paused.load(.monotonic);
        }

        pub fn isRunning(self: *Self) bool {
            return self.running.load(.monotonic);
        }

        pub fn publish(self: *Self, payload: UserPayload, filter_id: FilterId) !void {
            if (self.paused.load(.monotonic)) return;

            const topic = std.meta.activeTag(payload);
            const index = @intFromEnum(topic);

            self.locks[index].lockShared();
            defer self.locks[index].unlockShared();

            const subs = self.registry[index].items;
            if (subs.len == 0) return;

            var target_count: usize = 0;
            for (subs) |sub| {
                const raw = sub.filter_id.load(.monotonic);
                const sub_id: FilterId = @enumFromInt(raw);
                if (filter_id == .all or sub_id == filter_id) {
                    target_count += 1;
                }
            }
            if (target_count == 0) return;

            var envelope: ?*RcEnvelope = null;
            var final_payload = payload;

            const can_clone = @hasDecl(UserPayload, "clone");

            var use_envelope = false;
            if (@hasDecl(UserPayload, "needsClone")) {
                use_envelope = payload.needsClone();
            } else if (can_clone) {
                use_envelope = true;
            }

            if (use_envelope) {
                if (comptime !can_clone) {
                    return error.PayloadMissingCloneMethod;
                } else {
                    const env = try self.allocator.create(RcEnvelope);
                    errdefer self.allocator.destroy(env);

                    env.arena = std.heap.ArenaAllocator.init(self.allocator);
                    errdefer env.arena.deinit();

                    final_payload = try payload.clone(env.arena.allocator());

                    env.filter_id = filter_id;
                    env.ref_count = std.atomic.Value(usize).init(target_count);
                    envelope = env;
                }
            }

            for (subs) |sub| {
                const raw = sub.filter_id.load(.monotonic);
                const sub_id: FilterId = @enumFromInt(raw);

                if (filter_id == .all or sub_id == filter_id) {
                    sub.push(.{ .data = .{ .payload = final_payload, .envelope = envelope } }) catch {
                        if (envelope) |e| e.release(self.allocator);
                    };
                }
            }
        }

        fn unsubscribeRaw(self: *Self, topic: Topic, sub: *Subscriber) void {
            const index = @intFromEnum(topic);
            self.locks[index].lock();
            defer self.locks[index].unlock();

            var list = &self.registry[index];
            for (list.items, 0..) |item, i| {
                if (item == sub) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }
    };
}
