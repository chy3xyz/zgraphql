/// Server Example
/// ============================================================================
/// This example demonstrates a production-ready HTTP GraphQL server with:
///   - SchemaBuilder with resolvers
///   - Query cache (persisted queries / whitelist)
///   - Rate limiting
///   - Response caching
///   - Metrics collection
///   - Field-level authorization via hooks
///   - Graceful shutdown on SIGINT/SIGTERM
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

/// Custom panic handler for production: logs the panic before aborting.
/// In a real deployment you may want to send this to a crash reporting service.
pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        std.log.err("PANIC: {s}", .{msg});
        std.process.exit(1);
    }
}.panic);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build schema using compile-time SchemaBuilder
    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
            .user = .{ .type = "User", .args = .{ .id = .{ .type = "ID!" } } },
        },
        .User = .{
            .name = .{ .type = "String!" },
            .email = .{ .type = "String" },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    // Attach resolvers
    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // User resolver requires 'admin' role
    if (schema_def.query_type.kind.object.fields.getPtr("user")) |field| {
        field.required_role = "admin";
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                _ = args;
                var user = zg.Value.initObject(alloc);
                try user.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, 1));
                try user.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, "Alice")));
                try user.data.object.put(try alloc.dupe(u8, "email"), zg.Value.fromString(alloc, try alloc.dupe(u8, "alice@example.com")));
                return user;
            }
        }.resolve;
    }

    std.debug.print("Schema built with {d} types\n", .{schema_def.types.count()});
    std.debug.print("Generated SDL:\n{s}\n", .{Builder.sdl});

    // Setup query cache (persisted queries / whitelist)
    var cache = zg.QueryCache.init(allocator);
    defer cache.deinit();
    try cache.store("{ hello }");
    try cache.store("{ user(id: 1) { name email } }");

    // Setup metrics
    var metrics = zg.MetricsCollector.init(allocator);
    defer metrics.deinit();

    // Setup rate limiter: 10 req/s burst, 100 tokens capacity
    var rate_limiter = zg.RateLimiter.init(allocator, 100, 10);
    defer rate_limiter.deinit();

    // Setup response cache: 5 second TTL
    var response_cache = zg.ResponseCache.init(allocator, 5000);
    defer response_cache.deinit();

    // User context shared across hooks (roles, metrics pointer, etc.)
    const UserContext = struct {
        metrics: *zg.MetricsCollector,
        roles: []const []const u8,
    };
    var user_ctx = UserContext{
        .metrics = &metrics,
        .roles = &.{ "user" }, // change to &.{ "user", "admin" } to access user field
    };

    // Setup execution hooks for logging, auth, and metrics
    const hooks = zg.ExecutionHooks{
        .before_field_execute = struct {
            fn hook(_: ?*anyopaque, field_name: []const u8) bool {
                std.log.info("executing field: {s}", .{field_name});
                return true; // allow execution
            }
        }.hook,
        .after_field_execute = struct {
            fn hook(ctx: ?*anyopaque, field_name: []const u8, had_error: bool, duration_ns: u64) void {
                const uctx = @as(*UserContext, @ptrCast(@alignCast(ctx.?)));
                uctx.metrics.recordResolver(field_name, duration_ns, had_error);
            }
        }.hook,
        .on_error = struct {
            fn hook(_: ?*anyopaque, message: []const u8) void {
                std.log.warn("graphql error: {s}", .{message});
            }
        }.hook,
        .hasRole = struct {
            fn hook(ctx: ?*anyopaque, role: []const u8) bool {
                const uctx = @as(*UserContext, @ptrCast(@alignCast(ctx.?)));
                for (uctx.roles) |r| {
                    if (std.mem.eql(u8, r, role)) return true;
                }
                return false;
            }
        }.hook,
    };

    // Start server with production options
    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 15,
        .max_body_size = 1024 * 1024,
        .query_cache = &cache,
        // .enforce_query_whitelist = true, // uncomment to reject unknown queries
        .metrics = &metrics,
        .hooks = hooks,
        .rate_limiter = &rate_limiter,
        .response_cache = &response_cache,
        .user_data = &user_ctx,
    });

    // Initialize Io backend.
    // On Linux: use Io.Uring for io_uring (true async I/O)
    // On macOS/BSD/others: use Io.Threaded as a stable fallback
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    std.debug.print("Starting GraphQL server on http://127.0.0.1:8080/graphql\n", .{});
    std.debug.print("Metrics: http://127.0.0.1:8080/graphql/metrics\n", .{});
    std.debug.print("Try: curl -X POST http://127.0.0.1:8080/graphql -H 'Content-Type: application/json' -d '{s}'\n", .{"{\"query\":\"{ hello user { name email } }\"}"});

    try server.listen(io);
}
