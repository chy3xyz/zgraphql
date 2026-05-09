/// ============================================================================
/// Server Example / 服务器示例
/// ============================================================================
/// This example demonstrates a production-ready HTTP GraphQL server with:
///   - SchemaBuilder with resolvers
///   - Query cache (persisted queries / whitelist)
///   - Rate limiting
///   - Response caching
///   - Metrics collection
///   - Field-level authorization via hooks
///   - Graceful shutdown on SIGINT/SIGTERM
///
/// 本示例演示了一个可用于生产的 HTTP GraphQL 服务器，包含：
///   - SchemaBuilder + Resolver
///   - 查询缓存（持久化查询 / 白名单）
///   - 速率限制
///   - 响应缓存
///   - 指标收集
///   - 基于 hooks 的字段级授权
///   - SIGINT/SIGTERM 优雅关闭
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

/// Custom panic handler for production: logs the panic before aborting.
/// In a real deployment you may want to send this to a crash reporting service.
/// 生产环境的自定义 panic 处理器：在终止前记录 panic 信息。
/// 在真实部署中，你可能想将其发送到崩溃报告服务。
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

    // Build schema using compile-time SchemaBuilder / 使用编译期 SchemaBuilder 构建 schema
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

    // Attach resolvers / 附加 resolver
    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // User resolver requires 'admin' role / user resolver 需要 'admin' 角色
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

    // Setup query cache (persisted queries / whitelist) / 设置查询缓存
    var cache = zg.QueryCache.init(allocator);
    defer cache.deinit();
    try cache.store("{ hello }");
    try cache.store("{ user(id: 1) { name email } }");

    // Setup metrics / 设置指标收集器
    var metrics = zg.MetricsCollector.init(allocator);
    defer metrics.deinit();

    // Setup rate limiter: 10 req/s burst, 100 tokens capacity / 设置速率限制器
    var rate_limiter = zg.RateLimiter.init(allocator, 100, 10);
    defer rate_limiter.deinit();

    // Setup response cache: 5 second TTL / 设置响应缓存：5 秒 TTL
    var response_cache = zg.ResponseCache.init(allocator, 5000);
    defer response_cache.deinit();

    // User context shared across hooks (roles, metrics pointer, etc.)
    // 在 hooks 间共享的用户上下文（角色、指标指针等）
    const UserContext = struct {
        metrics: *zg.MetricsCollector,
        roles: []const []const u8,
    };
    var user_ctx = UserContext{
        .metrics = &metrics,
        .roles = &.{ "user" }, // change to &.{ "user", "admin" } to access user field
                                // 改为 &.{ "user", "admin" } 即可访问 user 字段
    };

    // Setup execution hooks for logging, auth, and metrics
    // 设置执行 hooks 用于日志、授权和指标
    const hooks = zg.ExecutionHooks{
        .before_field_execute = struct {
            fn hook(_: ?*anyopaque, field_name: []const u8) bool {
                std.log.info("executing field: {s}", .{field_name});
                return true; // allow execution / 允许执行
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

    // Start server with production options / 以生产级选项启动服务器
    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 15,
        .max_body_size = 1024 * 1024, // 1MB / 1MB
        .query_cache = &cache,
        // .enforce_query_whitelist = true, // uncomment to reject unknown queries / 取消注释以拒绝未知查询
        .metrics = &metrics,
        .hooks = hooks,
        .rate_limiter = &rate_limiter,
        .response_cache = &response_cache,
        .user_data = &user_ctx,
    });

    // Initialize Io backend.
    // On Linux: use Io.Uring for io_uring (true async I/O)
    // On macOS/BSD/others: use Io.Threaded as a stable fallback
    // 初始化 Io 后端。
    // Linux：使用 Io.Uring 进行 io_uring（真正的异步 I/O）
    // macOS/BSD/其他：使用 Io.Threaded 作为稳定的后备方案
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    std.debug.print("Starting GraphQL server on http://127.0.0.1:8080/graphql\n", .{});
    std.debug.print("Metrics: http://127.0.0.1:8080/graphql/metrics\n", .{});
    std.debug.print("Try: curl -X POST http://127.0.0.1:8080/graphql -H 'Content-Type: application/json' -d '{s}'\n", .{"{\"query\":\"{ hello user { name email } }\"}"});

    try server.listen(io);
}
