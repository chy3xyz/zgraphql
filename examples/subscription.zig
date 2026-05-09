/// ============================================================================
/// Subscription Example / 订阅示例
/// ============================================================================
/// This example demonstrates WebSocket-based subscriptions using the
/// `graphql-ws` protocol. Subscriptions push real-time updates to clients.
///
/// 本示例演示了基于 WebSocket 的订阅，使用 `graphql-ws` 协议。
/// 订阅将实时更新推送给客户端。
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

/// Simulates a real-time data source (e.g., a message broker, event bus, or
/// database change stream). In production, this could be a Kafka consumer or
/// an in-memory channel.
///
/// 模拟实时数据源（例如消息代理、事件总线或数据库变更流）。
/// 在生产环境中，这可以是一个 Kafka 消费者或内存通道。
const EventBus = struct {
    var counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

    fn nextValue() i64 {
        return counter.fetchAdd(1, .seq_cst);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Schema with a subscription root / 带有订阅根类型的 Schema
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
    // In zgraphql, subscription resolvers are registered similarly to field
    // resolvers, but the executor treats them as streaming sources.
    //
    // 订阅 resolver：返回一个值的流。
    // 在 zgraphql 中，订阅 resolver 的注册方式与普通字段 resolver 类似，
    // 但执行器将其视为流式数据源。
    if (schema_def.subscription_type) |sub_type| {
        if (sub_type.kind.object.fields.getPtr("counter")) |field| {
            field.resolve = struct {
                fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                    _ = ctx;
                    return zg.Value.fromInt(alloc, EventBus.nextValue());
                }
            }.resolve;
        }
    }

    // Setup server / 设置服务器
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
