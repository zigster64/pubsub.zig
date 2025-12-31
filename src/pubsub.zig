const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

// ============================================================================
// PUBSUB ENGINE
// ============================================================================

pub fn PubSub(comptime UserPayload: type) type {
    const Topic = std.meta.Tag(UserPayload);
    const TopicCount = std.meta.fields(Topic).len;

    const RcEnvelope = struct {
        ref_count: std.atomic.Value(usize),
        arena: std.heap.ArenaAllocator,
        data: UserPayload,

        pub fn release(self: *@This(), parent_alloc: Allocator) void {
            if (self.ref_count.fetchSub(1, .monotonic) == 1) {
                var arena = self.arena;
                arena.deinit();
                parent_alloc.destroy(self);
            }
        }
    };

    const Message = struct {
        envelope: *RcEnvelope,
        payload: UserPayload,
        topic: Topic,

        pub fn deinit(self: @This(), allocator: Allocator) void {
            self.envelope.release(allocator);
        }
    };

    const Event = union(enum) {
        msg: Message,
        timeout: void,
        err: anyerror,
        quit: void,
    };

    const QueueItem = union(enum) {
        msg: *RcEnvelope,
        quit: void,
    };

    return struct {
        const Self = @This();

        allocator: Allocator,
        registry: [TopicCount]std.ArrayListUnmanaged(*Subscriber) = undefined,
        locks: [TopicCount]std.Thread.RwLock = undefined,
        paused: std.atomic.Value(bool) = .init(false),

        pub fn init(allocator: Allocator) Self {
            var self = Self{ .allocator = allocator };
            inline for (0..TopicCount) |i| {
                self.registry[i] = .empty;
                self.locks[i] = std.Thread.RwLock{};
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            inline for (0..TopicCount) |i| {
                self.registry[i].deinit(self.allocator);
            }
        }

        pub fn togglePause(self: *Self) void {
            _ = self.paused.swap(!self.paused.load(.acquire), .acq_rel);
        }

        pub fn pause(self: *Self) void {
            self.paused.store(true, .monotonic);
        }

        pub fn unpause(self: *Self) void {
            self.paused.store(false, .monotonic);
        }

        pub fn client(self: *Self) !Subscriber {
            return Subscriber.init(self.allocator, self);
        }

        pub fn publish(self: *Self, payload: UserPayload) !void {
            if (self.paused.load(.monotonic)) return;

            const topic = std.meta.activeTag(payload);
            const index = @intFromEnum(topic);

            self.locks[index].lockShared();
            defer self.locks[index].unlockShared();

            const subs = self.registry[index].items;
            if (subs.len == 0) return;

            const env = try self.allocator.create(RcEnvelope);
            errdefer self.allocator.destroy(env);

            env.arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer env.arena.deinit();
            env.ref_count = std.atomic.Value(usize).init(subs.len);

            if (@hasDecl(UserPayload, "clone")) {
                env.data = try payload.clone(env.arena.allocator());
            } else {
                env.data = payload;
            }

            for (subs) |sub| {
                try sub.push(.{ .msg = env });
            }
        }

        pub const Subscriber = struct {
            allocator: Allocator,
            parent: *Self,

            // CHANGED: Using std.Deque for true O(1) Push/Pop
            queue: std.Deque(QueueItem),

            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            subscriptions: std.ArrayListUnmanaged(Topic) = .empty,
            timeout_ns: ?u64 = null,

            pub fn init(allocator: Allocator, parent: *Self) !Subscriber {
                return .{
                    .allocator = allocator,
                    .parent = parent,
                    .queue = try std.Deque(QueueItem).initCapacity(allocator, 1024),
                };
            }

            pub fn deinit(self: *Subscriber) void {
                for (self.subscriptions.items) |topic| {
                    self.parent.unsubscribeRaw(topic, self);
                }

                // Drain queue
                while (self.queue.popFront()) |item| {
                    switch (item) {
                        .msg => |env| env.release(self.allocator),
                        else => {},
                    }
                }

                self.subscriptions.deinit(self.allocator);
                self.queue.deinit(self.allocator);
            }

            pub fn subscribe(self: *Subscriber, topic: Topic) !void {
                const index = @intFromEnum(topic);
                self.parent.locks[index].lock();
                defer self.parent.locks[index].unlock();
                try self.parent.registry[index].append(self.parent.allocator, self);
                try self.subscriptions.append(self.allocator, topic);
            }

            pub fn setTimeout(self: *Subscriber, ns: u64) void {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.timeout_ns = ns;
            }

            pub fn push(self: *Subscriber, item: QueueItem) !void {
                self.mutex.lock();
                defer self.mutex.unlock();
                // Deque API: pushBack
                try self.queue.pushBack(self.allocator, item);
                self.cond.signal();
            }

            pub fn next(self: *Subscriber) Event {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.queue.len == 0) {
                    if (self.timeout_ns) |ns| {
                        self.cond.timedWait(&self.mutex, ns) catch |err| {
                            if (err == error.Timeout) return .timeout;
                            return .{ .err = err };
                        };
                    } else {
                        self.cond.wait(&self.mutex);
                    }
                }

                // Deque API: popFront returns ?T
                const item = self.queue.popFront() orelse return .{ .err = error.UnexpectedEmpty };

                switch (item) {
                    .msg => |env| return .{ .msg = Message{
                        .envelope = env,
                        .payload = env.data,
                        .topic = std.meta.activeTag(env.data),
                    } },
                    .quit => return .quit,
                }
            }
        };

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
