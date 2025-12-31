# Basic PubSub for Zig 0.16

This repo is just a test jig for setting up a PubSub service for use in Zig 0.16
with an example producer/consumer and broadcast pattern


## Create a Payload definition schema

The PubSub system transmits structured messages to consumers via a queue.

You need to define a strict schema that covers all the different types of messages ... but luckily
you just define this schema as Zig structs

Then wrap each struct in a tagged union

Example - in this app, we have messages for Cats, Prices, and SystemStatus messages only

```zig
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

```

## Create a PubSub based off a schema

## Connect to the PubSub object as a subscriber

## Subscribe to topics

## Publish to a topic


