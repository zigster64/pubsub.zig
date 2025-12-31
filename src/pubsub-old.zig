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
            if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
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

        io: Io,
        allocator: Allocator,
        registry: [TopicCount]std.ArrayListUnmanaged(*Subscriber) = undefined,
        locks: [TopicCount]std.Thread.RwLock = undefined,
        paused: std.atomic.Value(bool) = .init(false),

        pub fn init(io: Io, allocator: Allocator) Self {
            var self = Self{ .io = io, .allocator = allocator };
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

        pub fn sleep(self: *Self, delay: ?std.Io.Duration) void {
            self.paused.store(true, .monotonic);
            if (delay) |d| {
                self.io.sleep(d, .real) catch {};
                self.paused.store(false, .monotonic);
            }
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
                sub.push(.{ .msg = env }) catch {
                    env.release(self.allocator);
                };
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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const FilterId = @import("contract.zig").FilterId;


pub fn PubSub(comptime UserPayload: type) type {
    const Topic = std.meta.Tag(UserPayload);
    const TopicCount = std.meta.fields(Topic).len;

    // --------------------------------------------------------
    // Internal Types
    // --------------------------------------------------------

    // The "Heavy" Container (Only used for complex cloning)
    const RcEnvelope = struct {
        ref_count: std.atomic.Value(usize),
        arena: std.heap.ArenaAllocator,
        filter_id: FilterId,

        pub fn release(self: *@This(), parent_alloc: Allocator) void {
            // Atomic decrement. If we hit 1 (which means we were the last one), free it.
            if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
                var arena = self.arena;
                arena.deinit(); 
                parent_alloc.destroy(self); 
            }
        }
    };

    // The Hybrid Item: Carries value + optional ownership handle
    const QueueItem = struct {
        payload: UserPayload,
        envelope: ?*RcEnvelope, // Null for signals, Set for complex types
    };

    // Internal queue node
    const QueueNode = union(enum) {
        data: QueueItem,
        quit: void,
    };

    // --------------------------------------------------------
    // Public API Types
    // --------------------------------------------------------

    pub const Message = struct {
        envelope: ?*RcEnvelope,
        payload: UserPayload,
        topic: Topic,
        filter_id: FilterId,
        subscriber: *Subscriber,

        /// Manually release memory. 
        /// If you don't call this, mq.next() or mq.deinit() does it for you.
        pub fn deinit(self: @This(), allocator: Allocator) void {
            self.subscriber.manualRelease(self.envelope, allocator);
        }
    };

    pub const Event = union(enum) {
        msg: Message,
        timeout: void,
    };

    // --------------------------------------------------------
    // The Engine
    // --------------------------------------------------------

    return struct {
        const Self = @This();

        io: Io,
        allocator: Allocator,
        // Zig 0.16: ArrayList is now unmanaged (stores no allocator)
        registry: [TopicCount]std.ArrayList(*Subscriber) = undefined, 
        locks: [TopicCount]std.Thread.RwLock = undefined,
        paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(io: Io, allocator: Allocator) Self {
            var self = Self{ .io = io, .allocator = allocator };
            inline for (0..TopicCount) |i| {
                self.registry[i] = std.ArrayList(*Subscriber).init(allocator); // or .empty
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

        pub fn sleep(self: *Self, delay: ?Io.Duration) void {
            self.paused.store(true, .monotonic);
            if (delay) |d| {
                self.io.sleep(d, .real) catch {};
                self.paused.store(false, .monotonic);
            }
        }

        pub fn unpause(self: *Self) void {
            self.paused.store(false, .monotonic);
        }

        pub fn client(self: *Self) !Subscriber {
            return Subscriber.init(self.allocator, self);
        }

        // --------------------------------------------------------------------
        // PUBLISH (Hybrid & Filtered)
        // --------------------------------------------------------------------
        pub fn publish(self: *Self, payload: UserPayload, filter_id: FilterId) !void {
            if (self.paused.load(.monotonic)) return;

            const topic = std.meta.activeTag(payload);
            const index = @intFromEnum(topic);

            self.locks[index].lockShared();
            defer self.locks[index].unlockShared();

            const subs = self.registry[index].items;
            if (subs.len == 0) return; 

            // 1. Pre-flight Check (Atomic Peek)
            var target_count: usize = 0;
            for (subs) |sub| {
                const raw = sub.filter_id.load(.monotonic);
                const sub_id: FilterId = @enumFromInt(raw);
                
                // Match Logic: Broadcast (.all) OR Exact Match
                if (sub_id == .all or filter_id == .all or sub_id == filter_id) {
                    target_count += 1;
                }
            }
            if (target_count == 0) return; // Optimization: Zero Alloc if no listeners

            // 2. Hybrid Allocation Strategy
            var envelope: ?*RcEnvelope = null;
            var final_payload = payload;

            // REFLECTION: Only allocate if 'clone' exists
            if (@hasDecl(UserPayload, "clone")) {
                const env = try self.allocator.create(RcEnvelope);
                errdefer self.allocator.destroy(env);

                env.arena = std.heap.ArenaAllocator.init(self.allocator);
                errdefer env.arena.deinit();
                
                // Deep Copy to Arena
                final_payload = try payload.clone(env.arena.allocator());
                
                env.filter_id = filter_id;
                env.ref_count = std.atomic.Value(usize).init(target_count);
                envelope = env;
            } 
            // ELSE: It's POD/Void. Envelope stays null. Zero Alloc!

            // 3. Distribution Loop
            for (subs) |sub| {
                const raw = sub.filter_id.load(.monotonic);
                const sub_id: FilterId = @enumFromInt(raw);

                if (sub_id == .all or filter_id == .all or sub_id == filter_id) {
                    sub.push(.{ .data = .{ 
                        .payload = final_payload, 
                        .envelope = envelope 
                    }}) catch {
                        // Push failed (OOM)? Release the share we reserved.
                        if (envelope) |e| e.release(self.allocator);
                    };
                }
            }
        }

        // --------------------------------------------------------
        // Subscriber
        // --------------------------------------------------------

        pub const Subscriber = struct {
            allocator: Allocator,
            parent: *Self,
            queue: std.Deque(QueueNode), 
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            // Zig 0.16: ArrayList does not store allocator
            subscriptions: std.ArrayList(Topic) = .empty,
            // Atomic storage for Filter ID (u128)
            filter_id: std.atomic.Value(u128) = std.atomic.Value(u128).init(@intFromEnum(FilterId.all)),
            timeout_ns: ?u64 = null,
            
            // Safety: Tracks the message currently "loaned" to the user
            active_envelope: ?*RcEnvelope = null,

            pub fn init(allocator: Allocator, parent: *Self) !Subscriber {
                return .{
                    .allocator = allocator,
                    .parent = parent,
                    .queue = try std.Deque(QueueNode).initCapacity(allocator, 1024),
                };
            }

            pub fn deinit(self: *Subscriber) void {
                for (self.subscriptions.items) |topic| {
                    self.parent.unsubscribeRaw(topic, self);
                }
                // Cleanup dangling message
                if (self.active_envelope) |env| {
                    env.release(self.allocator);
                    self.active_envelope = null;
                }
                // Drain queue
                while (self.queue.popFront()) |item| {
                    switch (item) {
                        .data => |d| if (d.envelope) |e| e.release(self.allocator),
                        else => {},
                    }
                }
                self.subscriptions.deinit(self.allocator);
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

            // --- MAIN LOOP API ---

            /// Returns !?Event. 
            /// null = Quit (Stream Closed). 
            /// Event = .msg or .timeout.
            pub fn next(self: *Subscriber) !?Event {
                self.mutex.lock();
                defer self.mutex.unlock();

                // 1. AUTO-SAFETY: Release previous message if user forgot
                if (self.active_envelope) |env| {
                    env.release(self.allocator);
                    self.active_envelope = null;
                }

                while (self.queue.len() == 0) {
                    if (self.timeout_ns) |ns| {
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
                        // Track envelope to prevent leaks
                        if (d.envelope) |env| self.active_envelope = env;
                        
                        return Event{ 
                            .msg = Message{
                                .envelope = d.envelope,
                                .payload = d.payload,
                                .topic = std.meta.activeTag(d.payload),
                                .filter_id = if (d.envelope) |e| e.filter_id else .all,
                                .subscriber = self,
                            }
                        };
                    },
                    .quit => return null,
                }
            }

            /// Helper: Blocks until data arrives. Swallows timeouts.
            /// Returns payload directly.
            pub fn nextPayload(self: *Subscriber) !?UserPayload {
                while (true) {
                    const event = (try self.next()) orelse return null;
                    switch (event) {
                        .msg => |m| {
                            // Defer isn't strictly needed due to auto-cleanup, 
                            // but good for immediate release in tight loops.
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
                try self.subscriptions.append(self.allocator, topic);
            }

            pub fn push(self: *Subscriber, item: QueueNode) !void {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.queue.pushBack(self.allocator, item);
                self.cond.signal();
            }
        };

        fn unsubscribeRaw(self: *Self, topic: Topic, sub: *Subscriber) void {
             const index = @intFromEnum(topic);
            self.locks[index].lock();
            defer self.locks[index].unlock();
            
            var list = &self.registry[index];
            for (list.items, 0..) |item, i| {
                if (item == sub) {
                    // Zig 0.16: swapRemove is O(1) and needs no allocator
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }
    };
}
