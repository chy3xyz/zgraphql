/// Tenant Isolation Example
/// ============================================================================
/// This example demonstrates a multi-tenant GraphQL server where each
/// tenant has its own resource limits. Tenants are resolved from the
/// X-Tenant-ID request header.
///
///   Tenant-A: strict limits (depth=5, complexity=100, body=64KB)
///   Tenant-B: relaxed limits (depth=20, complexity=1000)
///   Default:  moderate limits when no tenant header is provided
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
            .nested = .{ .type = "Nested" },
        },
        .Nested = .{
            .a = .{ .type = "Nested" },
            .b = .{ .type = "Nested" },
            .c = .{ .type = "String" },
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

    // Configure tenant-specific rate limiters
    var rate_limiter_a = zg.RateLimiter.init(allocator, 100, 5);  // 5 req/s burst
    defer rate_limiter_a.deinit();
    var rate_limiter_b = zg.RateLimiter.init(allocator, 1000, 100); // 100 req/s burst
    defer rate_limiter_b.deinit();

    // Register tenants with independent limits
    var tm = zg.TenantManager.init(allocator);
    defer tm.deinit();

    try tm.register(.{
        .id = "tenant-a",
        .display_name = "Tenant A (strict)",
        .max_query_depth = 5,
        .max_query_complexity = 100,
        .max_body_size = 64 * 1024, // 64KB
        .rate_limiter = &rate_limiter_a,
        .roles = &.{"user"},
    });

    try tm.register(.{
        .id = "tenant-b",
        .display_name = "Tenant B (relaxed)",
        .max_query_depth = 20,
        .max_query_complexity = 1000,
        .max_body_size = 2 * 1024 * 1024, // 2MB
        .rate_limiter = &rate_limiter_b,
        .roles = &.{ "user", "admin" },
    });

    try tm.setDefault(.{
        .id = "default",
        .display_name = "Default Tenant",
        .max_query_depth = 10,
        .max_query_complexity = 500,
    });

    // Start server with tenant manager
    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 15, // global fallback
        .tenant_manager = &tm,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    std.debug.print("Multi-tenant GraphQL server on http://127.0.0.1:8080/graphql\n", .{});
    std.debug.print("\nRegistered tenants:\n", .{});
    std.debug.print("  tenant-a : depth=5,  complexity=100,  body=64KB,  rate=5/s\n", .{});
    std.debug.print("  tenant-b : depth=20, complexity=1000, body=2MB,  rate=100/s\n", .{});
    std.debug.print("  default  : depth=10, complexity=500  (no X-Tenant-ID header)\n", .{});
    std.debug.print("\nTry:\n", .{});
    std.debug.print("  Tenant A: curl -H 'X-Tenant-ID: tenant-a' -X POST ... -d '{s}'\n", .{"{\"query\":\"{ hello nested { a { b { c } } } }\"}"});
    std.debug.print("  Tenant B: curl -H 'X-Tenant-ID: tenant-b' -X POST ... -d '{s}'\n", .{"{\"query\":\"{ hello nested { a { b { c } } } }\"}"});

    try server.listen(io);
}
