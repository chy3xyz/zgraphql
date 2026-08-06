/// Subscription Example
/// ============================================================================
/// This example demonstrates WebSocket-based subscriptions using the
/// `graphql-ws` protocol. Subscriptions push real-time updates to clients.
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Schema with a subscription root
    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
        },
        .Subscription = .{
            .counter = .{ .type = "Int!" },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // Subscription resolver: returns a stream of values.
    // In zgraphql, subscription fields must bind `subscribe` (not `resolve`)
    // to a function that returns a `schema.SubscriptionStream`.
    if (schema_def.subscription_type) |sub_type| {
        if (sub_type.kind.object.fields.getPtr("counter")) |field| {
            field.subscribe = struct {
                const StreamCtx = struct {
                    current: i64 = 0,
                    max: i64 = 5,

                    fn next(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?zg.Value {
                        const ctx = @as(*StreamCtx, @ptrCast(@alignCast(ptr)));
                        if (ctx.current >= ctx.max) return null;
                        const v = ctx.current;
                        ctx.current += 1;
                        return zg.Value.fromInt(alloc, v);
                    }

                    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const ctx = @as(*StreamCtx, @ptrCast(@alignCast(ptr)));
                        alloc.destroy(ctx);
                    }
                };

                fn subscribe(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.schema.SubscriptionStream {
                    const ctx = try alloc.create(StreamCtx);
                    ctx.* = .{};
                    return zg.schema.SubscriptionStream{
                        .ptr = ctx,
                        .vtable = &.{
                            .next = StreamCtx.next,
                            .deinit = StreamCtx.deinit,
                        },
                    };
                }
            }.subscribe;
        }
    }

    // Setup server
    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 15,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    std.debug.print("Subscription server on ws://127.0.0.1:8080/graphql\n", .{});
    std.debug.print("WebSocket flow:\n", .{});
    std.debug.print("  1. Client sends: {{\"type\":\"connection_init\"}}\n", .{});
    std.debug.print("  2. Server replies: {{\"type\":\"connection_ack\"}}\n", .{});
    std.debug.print("  3. Client sends: {{\"type\":\"subscribe\",\"id\":\"1\",\"payload\":{{\"query\":\"subscription {{ counter }}\"}}}}\n", .{});
    std.debug.print("  4. Server pushes: {{\"type\":\"next\",\"id\":\"1\",\"payload\":{{\"data\":{{\"counter\":0}}}}}} ...\n", .{});

    try server.listen(io);
}
