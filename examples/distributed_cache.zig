/// Distributed Cache Example
/// ============================================================================
/// This example demonstrates two-tier caching:
///   L1: local ResponseCache (same-process, fast)
///   L2: SimpleMemoryBackend (simulates a remote cache service)
///
/// In production, replace SimpleMemoryBackend with HttpCacheBackend
/// pointing to Varnish, Nginx, or a custom cache proxy.
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
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

    // L1: local in-memory cache (5 second TTL)
    var l1_cache = zg.ResponseCache.init(allocator, 5000);
    defer l1_cache.deinit();

    // L2: simulated remote cache (SimpleMemoryBackend acts as a stand-in
    // for an external cache service like Redis or Memcached)
    var l2_backend = zg.SimpleMemoryBackend.init(allocator);
    defer l2_backend.deinit();

    var dc = zg.DistributedCache.init(
        allocator,
        l2_backend.cacheBackend(),
        "zgraphql:",
        &l1_cache,
    );
    defer dc.deinit();

    // Create a server that uses both L1 and L2 caches
    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 15,
        .response_cache = &l1_cache,
        .distributed_cache = &dc,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    std.debug.print("Distributed cache server on http://127.0.0.1:8080/graphql\n", .{});
    std.debug.print("L1 = ResponseCache (5s TTL), L2 = SimpleMemoryBackend\n", .{});
    std.debug.print("\nFirst query hits L2 (cold), subsequent queries hit L1 (hot).\n", .{});
    std.debug.print("Try: curl -X POST http://127.0.0.1:8080/graphql -H 'Content-Type: application/json' -d '{s}'\n", .{"{\"query\":\"{ hello }\"}"});

    try server.listen(io);
}
