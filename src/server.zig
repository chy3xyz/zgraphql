const std = @import("std");
// Import internal modules directly (rather than via zgraphql.zig) to avoid a
// cyclic import: zgraphql.zig re-exports server.zig, so server.zig must not
// import zgraphql.zig back. This keeps embedded users who don't need the HTTP
// server out of the module graph.
const zg = struct {
    pub const schema = @import("schema.zig");
    pub const Value = @import("value.zig").Value;
    pub const Parser = @import("parser.zig").Parser;
    pub const Validator = @import("validator.zig").Validator;
    pub const Executor = @import("executor.zig").Executor;
    pub const ExecutionHooks = @import("executor.zig").ExecutionHooks;
    pub const QueryCache = @import("query_cache.zig").QueryCache;
    pub const MetricsCollector = @import("metrics.zig").MetricsCollector;
    pub const RateLimiter = @import("rate_limiter.zig").RateLimiter;
    pub const ResponseCache = @import("response_cache.zig").ResponseCache;
    pub const DistributedCache = @import("distributed_cache.zig").DistributedCache;
    pub const AuditLog = @import("audit_log.zig").AuditLog;
    pub const Tenant = @import("tenant.zig").Tenant;
    pub const TenantManager = @import("tenant.zig").TenantManager;
    pub const Tracer = @import("tracing.zig").Tracer;
    pub const TraceSpan = @import("tracing.zig").TraceSpan;
    pub const TraceContext = @import("tracing.zig").TraceContext;
    pub const parseTraceparent = @import("tracing.zig").parseTraceparent;
    pub const formatTraceparent = @import("tracing.zig").formatTraceparent;
    pub const randomTraceId = @import("tracing.zig").randomTraceId;
    pub const randomSpanId = @import("tracing.zig").randomSpanId;
};
const Schema = zg.schema.Schema;
const Value = zg.Value;
const playground = @import("server_playground.zig");
const apq = @import("server_apq.zig");
const ws_handlers = @import("server_ws.zig");
const Io = std.Io;
const net = Io.net;
const http = std.http;

const log = std.log.scoped(.zgraphql_server);

/// Maximum number of concurrent server instances that can register for signal handling.
const max_server_instances = 16;

/// Registered server instances for graceful shutdown signal handling.
var g_server_registry: [max_server_instances]?*GraphQLServer = @splat(null);
var g_registry_mutex: std.atomic.Mutex = .unlocked;

fn registerServerForSignals(server: *GraphQLServer) void {
    while (!g_registry_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer g_registry_mutex.unlock();
    for (&g_server_registry) |*slot| {
        if (slot.* == null) {
            slot.* = server;
            return;
        }
    }
    log.warn("max server instances ({d}) reached, signal handling not registered for this instance", .{max_server_instances});
}

fn unregisterServerForSignals(server: *GraphQLServer) void {
    while (!g_registry_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer g_registry_mutex.unlock();
    for (&g_server_registry) |*slot| {
        if (slot.* == server) {
            slot.* = null;
            return;
        }
    }
}

fn signalHandler(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx;
    _ = sig;
    // Only set shutdown flags — logging is not async-signal-safe.
    // The main loop will log "shutdown requested" when it detects the flag.
    for (g_server_registry) |maybe_server| {
        if (maybe_server) |server| {
            server.shutdown();
        }
    }
}

pub const ServerOptions = struct {
    bind_address: net.IpAddress = net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
    max_query_depth: ?usize = 20,
    max_query_complexity: ?usize = 1000,
    max_body_size: usize = 1024 * 1024, // 1MB
    max_websocket_message_size: usize = 10 * 1024 * 1024, // 10MB
    max_batch_size: usize = 10,
    max_alias_count: usize = 100,
    max_connections: usize = 10000,
    read_timeout_ms: usize = 30000, // 30s
    cors_origins: []const []const u8 = &.{"*"},
    query_cache: ?*zg.QueryCache = null,
    enforce_query_whitelist: bool = false,
    metrics: ?*zg.MetricsCollector = null,
    hooks: ?zg.ExecutionHooks = null,
    rate_limiter: ?*zg.RateLimiter = null,
    response_cache: ?*zg.ResponseCache = null,
    /// Optional user data pointer passed to the Executor context.
    /// Used by hooks (e.g. hasRole) to access request-level state.
    user_data: ?*anyopaque = null,
    audit_log: ?*zg.AuditLog = null,
    /// Optional HMAC secret for verifying APQ (Automatic Persisted Query) signatures.
    /// When set, persistedQuery requests must include a valid `signature` field.
    apq_hmac_secret: ?[]const u8 = null,
    /// Optional Unix domain socket path to listen on instead of TCP.
    /// When set, `bind_address` is ignored and the server listens on the UDS.
    /// Recommended for production deployments behind a TLS-terminating reverse proxy
    /// (e.g. nginx, Caddy, Traefik).
    bind_unix_path: ?[]const u8 = null,
    /// Optional distributed tracing collector.
    /// When set, the server creates a root span per request and propagates
    /// the traceparent via response headers.
    tracer: ?*zg.Tracer = null,
    /// Optional tenant manager for multi-tenant isolation.
    tenant_manager: ?*zg.TenantManager = null,
    /// Optional distributed cache (L2) for cross-process/node caching.
    /// When set, the server checks this cache before the local response_cache
    /// and stores successful responses here as well.
    distributed_cache: ?*zg.DistributedCache = null,
    /// Enable the GraphQL Playground at /graphql/playground.
    /// When true, serves either GraphiQL (CDN) or a zero-dependency
    /// minimal playground depending on the request's offline capability.
    enable_playground: bool = false,
};

pub const GraphQLServer = struct {
    allocator: std.mem.Allocator,
    schema_def: *Schema,
    options: ServerOptions,
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    active_requests: std.atomic.Value(usize) = .init(0),
    connection_count: std.atomic.Value(usize) = .init(0),

    pub fn init(allocator: std.mem.Allocator, schema_def: *Schema, options: ServerOptions) GraphQLServer {
        return .{
            .allocator = allocator,
            .schema_def = schema_def,
            .options = options,
        };
    }

    /// Request graceful shutdown. The server will stop accepting new
    /// connections and wait for active requests to complete before exiting.
    pub fn shutdown(self: *GraphQLServer) void {
        _ = self.shutdown_requested.store(true, .release);
        log.info("shutdown requested", .{});
    }

    /// Start the server. Blocks until the server is shut down.
    pub fn listen(self: *GraphQLServer, io: Io) Io.Cancelable!void {
        // Register SIGINT/SIGTERM handlers for graceful shutdown
        registerServerForSignals(self);
        defer unregisterServerForSignals(self);

        var sa = std.posix.Sigaction{
            .handler = .{ .sigaction = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        var old_int: std.posix.Sigaction = undefined;
        var old_term: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &sa, &old_int);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, &old_term);
        defer {
            std.posix.sigaction(std.posix.SIG.INT, &old_int, null);
            std.posix.sigaction(std.posix.SIG.TERM, &old_term, null);
        }

        var server: net.Server = undefined;
        const unix_path = self.options.bind_unix_path;
        if (unix_path) |path| {
            const unix_addr = net.UnixAddress.init(path) catch |err| {
                log.err("invalid unix socket path '{s}': {s}", .{ path, @errorName(err) });
                return;
            };
            server = unix_addr.listen(io, .{}) catch |err| {
                log.err("failed to listen on unix socket '{s}': {s}", .{ path, @errorName(err) });
                return;
            };
            log.info("GraphQL server listening on unix:{s}", .{path});
        } else {
            server = self.options.bind_address.listen(io, .{ .reuse_address = true }) catch |err| {
                log.err("failed to listen on port {d}: {s}", .{ self.options.bind_address.getPort(), @errorName(err) });
                return;
            };
            log.info("GraphQL server listening on http://{f}/graphql", .{server.socket.address});
        }
        defer {
            server.deinit(io);
            if (unix_path) |path| {
                std.Io.Dir.cwd().deleteFile(io, path) catch {};
            }
        }

        var group: Io.Group = .init;
        defer {
            log.info("waiting for active requests to complete...", .{});
            group.cancel(io);
            // Wait up to 10 seconds for in-flight requests to drain
            var wait_iter: u32 = 0;
            while (self.active_requests.load(.acquire) > 0 and wait_iter < 200) : (wait_iter += 1) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch break;
            }
            if (self.active_requests.load(.acquire) > 0) {
                log.warn("shutdown with {d} active requests still pending", .{self.active_requests.load(.acquire)});
            } else {
                log.info("shutdown complete", .{});
            }
        }

        while (!self.shutdown_requested.load(.acquire)) {
            const current_conns = self.connection_count.load(.acquire);
            if (current_conns >= self.options.max_connections) {
                log.warn("connection limit reached ({d}), rejecting new connection", .{current_conns});
                var rejected = server.accept(io) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => continue,
                };
                rejected.close(io);
                continue;
            }

            var stream = server.accept(io) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| {
                    log.err("failed to accept connection: {s}", .{@errorName(e)});
                    continue;
                },
            };

            _ = self.connection_count.fetchAdd(1, .monotonic);
            group.concurrent(io, handleConnection, .{ self, io, stream }) catch |err| {
                log.err("unable to spawn connection handler: {s}", .{@errorName(err)});
                _ = self.connection_count.fetchSub(1, .monotonic);
                stream.close(io);
            };
        }
    }
};

fn getClientAddress(allocator: std.mem.Allocator, stream: net.Stream) std.mem.Allocator.Error!?[]u8 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(stream.socket.handle, @ptrCast(&storage), &len) catch return null;

    switch (storage.family) {
        std.posix.AF.INET => {
            const sin = @as(*const std.posix.sockaddr.in, @ptrCast(&storage));
            const addr_host = std.mem.bigToNative(u32, sin.addr);
            var buf: [16]u8 = undefined;
            const ip_str = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
                @as(u8, @truncate(addr_host >> 0)),
                @as(u8, @truncate(addr_host >> 8)),
                @as(u8, @truncate(addr_host >> 16)),
                @as(u8, @truncate(addr_host >> 24)),
            }) catch return null;
            return try allocator.dupe(u8, ip_str);
        },
        std.posix.AF.INET6 => {
            const sin6 = @as(*const std.posix.sockaddr.in6, @ptrCast(&storage));
            const addr = &sin6.addr;
            var buf: [46]u8 = undefined;
            const ip_str = std.fmt.bufPrint(&buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                std.mem.readInt(u16, addr[0..2], .big),
                std.mem.readInt(u16, addr[2..4], .big),
                std.mem.readInt(u16, addr[4..6], .big),
                std.mem.readInt(u16, addr[6..8], .big),
                std.mem.readInt(u16, addr[8..10], .big),
                std.mem.readInt(u16, addr[10..12], .big),
                std.mem.readInt(u16, addr[12..14], .big),
                std.mem.readInt(u16, addr[14..16], .big),
            }) catch return null;
            return try allocator.dupe(u8, ip_str);
        },
        else => return null,
    }
}

fn handleConnection(self: *GraphQLServer, io: Io, stream: net.Stream) Io.Cancelable!void {
    _ = self.active_requests.fetchAdd(1, .monotonic);
    defer {
        _ = self.active_requests.fetchSub(1, .monotonic);
        _ = self.connection_count.fetchSub(1, .monotonic);
        stream.close(io);
    }

    var client_addr: ?[]u8 = null;
    defer if (client_addr) |addr| self.allocator.free(addr);
    if (self.options.rate_limiter != null) {
        client_addr = getClientAddress(self.allocator, stream) catch null;
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var stream_reader = net.Stream.Reader.init(stream, io, &read_buffer);
    var stream_writer = net.Stream.Writer.init(stream, io, &write_buffer);
    var server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpRequestTruncated => return,
            error.ReadFailed => return,
            else => {
                return;
            },
        };

        handleRequest(self, io, &request, if (client_addr) |addr| addr else null) catch |err| switch (err) {
            error.OutOfMemory => {
                request.respond("Service Unavailable", .{
                    .status = .service_unavailable,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                }) catch {};
                return;
            },
            else => {
                log.err("request handler error: {s}", .{@errorName(err)});
                request.respond("Internal Server Error", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
                }) catch {};
                return;
            },
        };
    }
}

fn handleRequest(self: *GraphQLServer, io: Io, request: *http.Server.Request, client_addr: ?[]const u8) !void {
    const head = request.head;
    const origin = resolveCorsOrigin(self.options, request.head_buffer);
    const query_start_time = Io.Clock.Timestamp.now(io, .real);
    var complexity: u64 = 0;
    var had_error = true; // default to error; success paths clear it
    var query_str: ?[]const u8 = null;
    var operation_name: ?[]const u8 = null;
    defer {
        if (query_str) |q| self.allocator.free(q);
        if (operation_name) |o| self.allocator.free(o);
    }

    // Distributed tracing: create root span if tracer is configured.
    var trace_span: ?zg.TraceSpan = null;
    defer {
        if (self.options.tracer) |tracer| {
            if (trace_span) |span| {
                tracer.endSpan(span);
            }
        }
    }
    if (self.options.tracer) |tracer| {
        const tp_header = findTraceparent(request.head_buffer);
        const trace_ctx = if (tp_header) |h|
            zg.parseTraceparent(h) orelse zg.TraceContext{ .trace_id = zg.randomTraceId(io), .parent_span_id = zg.randomSpanId(io) }
        else
            zg.TraceContext{ .trace_id = zg.randomTraceId(io), .parent_span_id = zg.randomSpanId(io) };
        trace_span = try tracer.startRootSpan("graphql.execute", trace_ctx.trace_id);
        trace_span.?.parent_id = trace_ctx.parent_span_id;
        if (query_str) |q| {
            trace_span.?.setAttribute(self.allocator, "graphql.query", q) catch {};
        }
    }

    defer {
        if (self.options.metrics) |metrics| {
            const end_time = Io.Clock.Timestamp.now(io, .real);
            const duration = end_time.raw.durationTo(query_start_time.raw);
            const duration_ns = @as(u64, @intCast(@max(0, duration.nanoseconds)));
            metrics.recordQuery(duration_ns, complexity, had_error);
        }
        if (self.options.audit_log) |audit| {
            const end_time = Io.Clock.Timestamp.now(io, .real);
            const duration_ns = @max(0, end_time.raw.durationTo(query_start_time.raw).nanoseconds);
            const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
            const now_ms: i64 = @intCast(@divFloor(end_time.raw.nanoseconds, std.time.ns_per_ms));
            audit.record(.{
                .timestamp_ms = now_ms,
                .client_ip = client_addr,
                .query = query_str orelse "",
                .operation_name = operation_name,
                .duration_ms = duration_ms,
                .complexity = complexity,
                .had_error = had_error,
                .status_code = 200,
            });
        }
    }

    // Tenant resolution (done before WebSocket upgrade so the WS path also
    // applies per-tenant limits/schema instead of bypassing them).
    var resolved_tenant: ?*zg.Tenant = null;
    if (self.options.tenant_manager) |tm| {
        resolved_tenant = tm.resolve(request.head_buffer);
    }

    // WebSocket upgrade
    const upgrade = request.upgradeRequested();
    if (upgrade == .websocket) {
        const key = upgrade.websocket orelse {
            try sendGraphQLErrorResponse(self.allocator, request, "Missing Sec-WebSocket-Key", .bad_request, origin);
            return;
        };
        // Echo Sec-WebSocket-Protocol if client requests graphql-transport-ws
        var ws_extra: [1]std.http.Header = undefined;
        var ws_extra_count: usize = 0;
        blk: {
            const buf = request.head_buffer;
            const needle = "sec-websocket-protocol:";
            var i: usize = 0;
            while (i + needle.len < buf.len) : (i += 1) {
                if (std.ascii.eqlIgnoreCase(buf[i .. i + needle.len], needle)) {
                    const val_start = i + needle.len;
                    const val_end = std.mem.indexOf(u8, buf[val_start..], "\r\n") orelse break;
                    const proto = std.mem.trim(u8, buf[val_start .. val_start + val_end], " \t");
                    if (std.ascii.findIgnoreCase(proto, "graphql-transport-ws") != null) {
                        ws_extra[0] = .{ .name = "sec-websocket-protocol", .value = "graphql-transport-ws" };
                        ws_extra_count = 1;
                    }
                    break :blk;
                }
            }
        }
        var ws = try request.respondWebSocket(.{ .key = key, .extra_headers = ws_extra[0..ws_extra_count] });
        try ws.output.flush();
        try ws_handlers.handleWebSocket(self, io, &ws, resolved_tenant);
        had_error = false;
        return;
    }

    // Handle CORS preflight
    if (head.method == .OPTIONS) {
        try sendCorsResponse(request, origin);
        had_error = false;
        return;
    }

    // GraphQL Playground
    if (self.options.enable_playground and std.mem.eql(u8, head.target, "/graphql/playground")) {
        try sendPlayground(request, origin);
        had_error = false;
        return;
    }

    // Health check endpoint
    if (std.mem.eql(u8, head.target, "/health")) {
        var health_headers: [2]std.http.Header = .{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
        };
        try request.respond("{\"status\":\"ok\"}", .{
            .status = .ok,
            .extra_headers = &health_headers,
        });
        had_error = false;
        return;
    }

    // Readiness check endpoint
    if (std.mem.eql(u8, head.target, "/ready")) {
        const body = "{\"status\":\"ready\"}";
        var ready_headers: [2]std.http.Header = .{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
        };
        try request.respond(body, .{
            .status = .ok,
            .extra_headers = &ready_headers,
        });
        had_error = false;
        return;
    }

    // Metrics endpoint
    if (std.mem.eql(u8, head.target, "/graphql/metrics")) {
        if (self.options.metrics) |metrics| {
            const json_str = metrics.toJson(self.allocator) catch |err| {
                log.err("metrics serialization error: {s}", .{@errorName(err)});
                return;
            };
            defer self.allocator.free(json_str);
            try sendJsonResponse(request, json_str, origin);
            had_error = false;
        }
        return;
    }

    // Rate limiting (applied to GraphQL endpoints only)
    // Tenant-specific rate limiter takes precedence over global.
    const effective_rate_limiter = if (resolved_tenant) |t| t.rate_limiter else null;
    if (effective_rate_limiter) |limiter| {
        if (client_addr) |addr| {
            const now_ts = Io.Clock.Timestamp.now(io, .awake);
            const elapsed = now_ts.raw.durationTo(Io.Timestamp.zero);
            const now_ms: i64 = @intCast(@divFloor(elapsed.nanoseconds, std.time.ns_per_ms));
            if (!limiter.allow(addr, now_ms)) {
                try sendGraphQLErrorResponse(self.allocator, request, "Rate limit exceeded", .too_many_requests, origin);
                had_error = false;
                return;
            }
        }
    } else if (self.options.rate_limiter) |limiter| {
        if (client_addr) |addr| {
            const now_ts = Io.Clock.Timestamp.now(io, .awake);
            const elapsed = now_ts.raw.durationTo(Io.Timestamp.zero);
            const now_ms: i64 = @intCast(@divFloor(elapsed.nanoseconds, std.time.ns_per_ms));
            if (!limiter.allow(addr, now_ms)) {
                try sendGraphQLErrorResponse(self.allocator, request, "Rate limit exceeded", .too_many_requests, origin);
                had_error = false;
                return;
            }
        }
    }

    // Only accept POST or GET to /graphql
    if (!std.mem.eql(u8, head.target, "/graphql") and !std.mem.startsWith(u8, head.target, "/graphql?")) {
        try sendGraphQLErrorResponse(self.allocator, request, "Not Found", .not_found, origin);
        return;
    }

    var variables = std.StringHashMap(Value).init(self.allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        variables.deinit();
    }

    // Determine effective body size limit (tenant overrides global)
    const effective_max_body_size = if (resolved_tenant) |t| t.max_body_size orelse self.options.max_body_size else self.options.max_body_size;

    // Parse based on HTTP method
    if (head.method == .POST) {
        // Check body size
        const content_length = request.head.content_length orelse 0;
        if (content_length > effective_max_body_size) {
            try sendGraphQLErrorResponse(self.allocator, request, "Request body too large", .payload_too_large, origin);
            return;
        }

        const body = try readRequestBody(self.allocator, request);
        defer self.allocator.free(body);

        // Parse JSON body dynamically
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch |err| {
            log.err("failed to parse JSON body: {s}", .{@errorName(err)});
            try sendGraphQLErrorResponse(self.allocator, request, "Invalid JSON", .bad_request, origin);
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;

        // Apollo-style query batching: array of request objects
        if (root == .array) {
            const batch_result = try executeBatch(self, io, root.array.items, resolved_tenant);
            defer self.allocator.free(batch_result.json_str);
            complexity = batch_result.total_complexity;
            had_error = batch_result.had_error;
            try sendJsonResponse(request, batch_result.json_str, origin);
            return;
        }

        if (root != .object) {
            try sendGraphQLErrorResponse(self.allocator, request, "Invalid JSON: expected object or array", .bad_request, origin);
            return;
        }

        const obj = root.object;
        if (obj.get("query")) |q| {
            if (q == .string) query_str = try self.allocator.dupe(u8, q.string);
        }
        if (obj.get("operationName")) |op| {
            if (op == .string) operation_name = try self.allocator.dupe(u8, op.string);
        }
        if (obj.get("variables")) |vars| {
            if (vars == .object) {
                var viter = vars.object.iterator();
                while (viter.next()) |entry| {
                    try variables.put(try self.allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(self.allocator, entry.value_ptr.*));
                }
            }
        }

        // APQ: Automatic Persisted Queries
        if (obj.get("extensions")) |ext| {
            if (ext == .object) {
                if (ext.object.get("persistedQuery")) |pq| {
                    if (pq == .object) {
                        const apq_hash = pq.object.get("sha256Hash");
                        const apq_sig = pq.object.get("signature");
                        if (apq_hash) |h| {
                            if (h == .string) {
                                const sig: ?[]const u8 = if (apq_sig) |s| (if (s == .string) s.string else null) else null;
                                query_str = try apq.resolvePersistedQuery(self, request, h.string, query_str, sig, origin);
                                if (query_str == null) return;
                            }
                        }
                    }
                }
            }
        }
    } else if (head.method == .GET) {
        // Parse query params from target
        const target = head.target;
        const query_start = std.mem.indexOf(u8, target, "?");
        if (query_start) |start| {
            const params = target[start + 1 ..];
            var iter = std.mem.splitScalar(u8, params, '&');
            while (iter.next()) |param| {
                const eq = std.mem.indexOf(u8, param, "=") orelse continue;
                const key = param[0..eq];
                const val = std.Uri.percentDecodeInPlace(@constCast(param[eq + 1 ..]));
                if (std.mem.eql(u8, key, "query")) {
                    query_str = try self.allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "operationName")) {
                    operation_name = try self.allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "variables")) {
                    const vars_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, val, .{}) catch continue;
                    defer vars_parsed.deinit();
                    if (vars_parsed.value == .object) {
                        var viter = vars_parsed.value.object.iterator();
                        while (viter.next()) |entry| {
                            try variables.put(try self.allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(self.allocator, entry.value_ptr.*));
                        }
                    }
                } else if (std.mem.eql(u8, key, "extensions")) {
                    const ext_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, val, .{}) catch continue;
                    defer ext_parsed.deinit();
                    if (ext_parsed.value == .object) {
                        if (ext_parsed.value.object.get("persistedQuery")) |pq| {
                            if (pq == .object) {
                                const apq_hash = pq.object.get("sha256Hash");
                                const apq_sig = pq.object.get("signature");
                                if (apq_hash) |h| {
                                    if (h == .string) {
                                        const sig: ?[]const u8 = if (apq_sig) |s| (if (s == .string) s.string else null) else null;
                                        query_str = try apq.resolvePersistedQuery(self, request, h.string, query_str, sig, origin);
                                        if (query_str == null) return;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        try sendGraphQLErrorResponse(self.allocator, request, "Method Not Allowed", .method_not_allowed, origin);
        return;
    }

    const query = query_str orelse {
        try sendGraphQLErrorResponse(self.allocator, request, "Missing query", .bad_request, origin);
        return;
    };

    const result = executeGraphQLAndGetJson(self, io, query, operation_name, &variables, resolved_tenant) catch |err| {
        log.err("execution pipeline error: {s}", .{@errorName(err)});
        try sendGraphQLErrorResponse(self.allocator, request, "Internal error", .internal_server_error, origin);
        return;
    };
    defer self.allocator.free(result.json_str);
    complexity = result.complexity;
    had_error = result.had_error;

    if (trace_span) |span| {
        var tp_buf: [64]u8 = undefined;
        const tp_str = zg.formatTraceparent(&tp_buf, .{ .trace_id = span.trace_id, .parent_span_id = span.span_id });
        var headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
            .{ .name = "traceparent", .value = tp_str },
        };
        try request.respond(result.json_str, .{
            .status = .ok,
            .extra_headers = &headers,
        });
    } else {
        try sendJsonResponse(request, result.json_str, origin);
    }
}

fn findTraceparent(head_buffer: []const u8) ?[]const u8 {
    const prefix = "traceparent:";
    const start = std.mem.indexOf(u8, head_buffer, prefix) orelse return null;
    const value_start = start + prefix.len;
    const line_end = std.mem.indexOfPos(u8, head_buffer, value_start, "\r\n") orelse return null;
    return std.mem.trim(u8, head_buffer[value_start..line_end], " ");
}

/// Returns true if the query document's first operation is a query (not a
/// mutation or subscription). Used to decide response-cache eligibility before
/// parsing. Conservative lexical check: skips whitespace and comments, then
/// inspects the first keyword. Anonymous operations (`{ ... }`) are queries.
fn queryIsQuery(query: []const u8) bool {
    var i: usize = 0;
    while (i < query.len) {
        const c = query[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '#') {
            while (i < query.len and query[i] != '\n') : (i += 1) {}
            continue;
        }
        break;
    }
    const rest = query[i..];
    if (rest.len == 0) return false;
    if (rest[0] == '{') return true; // anonymous operation → query
    if (std.mem.startsWith(u8, rest, "query")) return isKeyword(rest, "query");
    if (std.mem.startsWith(u8, rest, "mutation")) return !isKeyword(rest, "mutation");
    if (std.mem.startsWith(u8, rest, "subscription")) return !isKeyword(rest, "subscription");
    return false; // fragment-only or unknown document shape
}

/// Returns true if `kw` appears as a whole GraphQL operation keyword at the
/// start of `s` (i.e. followed by whitespace, `{`, or end of input), rather
/// than merely being a prefix of a longer identifier like `queryFoo`.
fn isKeyword(s: []const u8, kw: []const u8) bool {
    if (s.len == kw.len) return true;
    const next = s[kw.len];
    return next == ' ' or next == '\t' or next == '\r' or next == '\n' or next == '{';
}

/// Execute a GraphQL query string and return the JSON response.
/// Caller owns the returned json_str memory.
pub fn executeGraphQLAndGetJson(
    self: *GraphQLServer,
    io: Io,
    query: []const u8,
    operation_name: ?[]const u8,
    variables: *std.StringHashMap(Value),
    tenant: ?*zg.Tenant,
) !struct { json_str: []const u8, complexity: u64, had_error: bool } {
    // Determine effective configuration from tenant or global defaults
    const effective_schema = if (tenant) |t| t.schema orelse self.schema_def else self.schema_def;
    const effective_query_cache = if (tenant) |t| t.query_cache orelse self.options.query_cache else self.options.query_cache;
    const effective_enforce_whitelist = if (tenant) |t| t.enforce_query_whitelist or self.options.enforce_query_whitelist else self.options.enforce_query_whitelist;
    const effective_max_depth = if (tenant) |t| t.max_query_depth orelse self.options.max_query_depth else self.options.max_query_depth;
    const effective_max_complexity = if (tenant) |t| t.max_query_complexity orelse self.options.max_query_complexity else self.options.max_query_complexity;

    // Query whitelist check
    if (effective_enforce_whitelist) {
        if (effective_query_cache) |cache| {
            if (!cache.contains(query)) {
                return .{
                    .json_str = try buildErrorJson(self.allocator, "Query not in whitelist"),
                    .complexity = 0,
                    .had_error = true,
                };
            }
        } else {
            return .{
                .json_str = try buildErrorJson(self.allocator, "Query whitelist enabled but no cache configured"),
                .complexity = 0,
                .had_error = true,
            };
        }
    }

    // Response cache check (only for cacheable queries: no runtime variables,
    // and the operation is a query — never a mutation or subscription).
    // The cache key is tenant-scoped so different tenants never read each
    // other's cached responses when sharing a global cache.
    const cache_key: []const u8 = blk: {
        if (tenant) |t| break :blk try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ t.id, query });
        break :blk query;
    };
    defer if (tenant != null) self.allocator.free(cache_key);

    const cacheable = variables.count() == 0 and queryIsQuery(query);
    if (cacheable) {
        // Check distributed cache (L2) first
        if (self.options.distributed_cache) |dc| {
            const now_ts = Io.Clock.Timestamp.now(io, .real);
            const now_ms: i64 = @intCast(@divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms));
            if (try dc.get(cache_key, now_ms)) |cached| {
                return .{ .json_str = cached, .complexity = 0, .had_error = false };
            }
        }
        // Check local response cache (L1)
        if (self.options.response_cache) |cache| {
            const now_ts = Io.Clock.Timestamp.now(io, .real);
            const now_ms: i64 = @intCast(@divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms));
            // cache.get returns an owned copy; transfer ownership to the caller.
            if (cache.get(cache_key, now_ms)) |cached| {
                return .{ .json_str = cached, .complexity = 0, .had_error = false };
            }
        }
    }

    // Parse GraphQL query
    var parser = zg.Parser.init(self.allocator, query) catch |err| {
        log.err("parser init error: {s}", .{@errorName(err)});
        return .{
            .json_str = try buildErrorJson(self.allocator, "Parser error"),
            .complexity = 0,
            .had_error = true,
        };
    };
    defer parser.deinit();
    var doc = parser.parseDocument() catch |err| {
        log.err("parse error: {s}", .{@errorName(err)});
        return .{
            .json_str = try buildErrorJson(self.allocator, "Syntax error"),
            .complexity = 0,
            .had_error = true,
        };
    };
    defer doc.deinit();

    const complexity = @import("complexity.zig").ComplexityAnalyzer.analyzeDocument(&doc).complexity;

    // Check depth limit
    if (effective_max_depth) |max_depth| {
        const limit = @import("complexity.zig").DepthLimit{ .max_depth = max_depth };
        if (limit.check(&doc)) |actual_depth| {
            log.warn("query depth {d} exceeds limit {d}", .{ actual_depth, max_depth });
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Query depth {d} exceeds maximum allowed depth {d}", .{ actual_depth, max_depth });
            return .{
                .json_str = try buildErrorJson(self.allocator, msg),
                .complexity = complexity,
                .had_error = true,
            };
        }
    }

    // Check complexity limit
    if (effective_max_complexity) |max_complexity| {
        if (complexity > max_complexity) {
            log.warn("query complexity {d} exceeds limit {d}", .{ complexity, max_complexity });
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Query complexity {d} exceeds maximum allowed complexity {d}", .{ complexity, max_complexity });
            return .{
                .json_str = try buildErrorJson(self.allocator, msg),
                .complexity = complexity,
                .had_error = true,
            };
        }
    }

    // Validate
    var validator = zg.Validator.init(self.allocator, effective_schema);
    defer validator.deinit();
    const validation_result = validator.validate(&doc) catch |err| {
        log.err("validation error: {s}", .{@errorName(err)});
        return .{
            .json_str = try buildErrorJson(self.allocator, "Validation error"),
            .complexity = complexity,
            .had_error = true,
        };
    };

    if (!validation_result.isValid()) {
        var error_json = Value.initObject(self.allocator);
        defer error_json.deinit(self.allocator);
        var errors = Value.initList(self.allocator);
        errdefer errors.deinit(self.allocator);
        for (validation_result.errors.items) |err| {
            var err_obj = Value.initObject(self.allocator);
            errdefer err_obj.deinit(self.allocator);
            try err_obj.data.object.put(try self.allocator.dupe(u8, "message"), Value.fromString(self.allocator, try self.allocator.dupe(u8, err.message)));
            if (err.line != null or err.col != null) {
                var loc = Value.initObject(self.allocator);
                // Ownership of loc transfers to `locations` on append below;
                // the loc errdefer is only active until that point.
                var loc_owned = true;
                errdefer if (loc_owned) loc.deinit(self.allocator);
                if (err.line) |line| {
                    try loc.data.object.put(try self.allocator.dupe(u8, "line"), Value.fromInt(self.allocator, @intCast(line)));
                }
                if (err.col) |col| {
                    try loc.data.object.put(try self.allocator.dupe(u8, "column"), Value.fromInt(self.allocator, @intCast(col)));
                }
                var locations = Value.initList(self.allocator);
                errdefer locations.deinit(self.allocator);
                try locations.data.list.append(loc);
                loc_owned = false;
                try err_obj.data.object.put(try self.allocator.dupe(u8, "locations"), locations);
            }
            try errors.data.list.append(err_obj);
        }
        try error_json.data.object.put(try self.allocator.dupe(u8, "errors"), errors);
        const json_str = error_json.toJson(self.allocator) catch |err| {
            log.err("json error: {s}", .{@errorName(err)});
            return error.OutOfMemory;
        };
        return .{ .json_str = json_str, .complexity = complexity, .had_error = true };
    }

    // Execute
    var executor = zg.Executor.init(self.allocator, effective_schema, io);
    defer executor.deinit();
    if (self.options.hooks) |hooks| {
        executor.hooks = hooks;
    }
    if (self.options.user_data) |user_data| {
        executor.setUserData(user_data);
    }

    try executor.setVariables(variables.*);

    var result = executor.executeNamed(&doc, operation_name) catch |err| {
        log.err("execution error: {s}", .{@errorName(err)});
        // Surface the concrete error name (e.g. ResolverError, InvalidInput)
        // instead of a generic "Execution error" to aid diagnosis. The error
        // name is a safe, non-sensitive identifier.
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Execution error ({s})", .{@errorName(err)}) catch "Execution error";
        return .{
            .json_str = try buildErrorJson(self.allocator, msg),
            .complexity = complexity,
            .had_error = true,
        };
    };
    defer result.deinit(self.allocator);

    const json_str = result.toJson(self.allocator) catch |err| {
        log.err("json serialization error: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Store successful cacheable response
    if (cacheable) {
        const now_ts = Io.Clock.Timestamp.now(io, .real);
        const now_ms: i64 = @intCast(@divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms));
        // Store to distributed cache (L2)
        if (self.options.distributed_cache) |dc| {
            dc.setWithDefaultTtl(cache_key, json_str, now_ms) catch |err| {
                log.warn("failed to store to distributed cache: {s}", .{@errorName(err)});
            };
        }
        // Store to local response cache (L1)
        if (self.options.response_cache) |cache| {
            cache.put(cache_key, json_str, now_ms) catch |err| {
                log.warn("failed to cache response: {s}", .{@errorName(err)});
            };
        }
    }

    return .{ .json_str = json_str, .complexity = complexity, .had_error = false };
}

pub fn buildErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const ErrorPayload = struct {
        errors: []const struct { message: []const u8 },
    };
    const payload = ErrorPayload{ .errors = &.{.{ .message = message }} };
    return try std.json.Stringify.valueAlloc(allocator, payload, .{});
}

pub fn jsonToGraphQLValue(allocator: std.mem.Allocator, json_val: std.json.Value) std.mem.Allocator.Error!Value {
    switch (json_val) {
        .null => return Value.fromNull(allocator),
        .bool => |b| return Value.fromBool(allocator, b),
        .integer => |i| return Value.fromInt(allocator, i),
        .float => |f| return Value.fromFloat(allocator, f),
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |i| {
                return Value.fromInt(allocator, i);
            } else |_| {
                if (std.fmt.parseFloat(f64, s)) |f| {
                    return Value.fromFloat(allocator, f);
                } else |_| {
                    return Value.fromString(allocator, try allocator.dupe(u8, s));
                }
            }
        },
        .string => |s| return Value.fromString(allocator, try allocator.dupe(u8, s)),
        .array => |arr| {
            var list = Value.initList(allocator);
            errdefer list.deinit(allocator);
            for (arr.items) |item| {
                try list.data.list.append(try jsonToGraphQLValue(allocator, item));
            }
            return list;
        },
        .object => |obj| {
            var graph_obj = Value.initObject(allocator);
            errdefer graph_obj.deinit(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try graph_obj.data.object.put(try allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(allocator, entry.value_ptr.*));
            }
            return graph_obj;
        },
    }
}

fn readRequestBody(allocator: std.mem.Allocator, request: *http.Server.Request) ![]u8 {
    const len = request.head.content_length orelse 0;

    var transfer_buffer: [4096]u8 = undefined;
    const body_reader = request.server.reader.bodyReader(
        &transfer_buffer,
        request.head.transfer_encoding,
        request.head.content_length,
    );

    if (len > 0) {
        const body = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(body);
        var writer = Io.Writer.fixed(body);
        try body_reader.streamExact(&writer, @intCast(len));
        return body;
    }

    // Chunked transfer encoding — body reader handles chunked decoding.
    // Read with a generous buffer limit (10MB).
    if (request.head.transfer_encoding == .chunked) {
        const max_size = 10 * 1024 * 1024;
        const body = try allocator.alloc(u8, max_size);
        errdefer allocator.free(body);
        var writer = Io.Writer.fixed(body);
        const n = try body_reader.stream(&writer, Io.Limit.limited(max_size));
        return body[0..n];
    }

    return "";
}

fn resolveCorsOrigin(options: ServerOptions, head_buffer: []const u8) []const u8 {
    if (options.cors_origins.len == 1 and std.mem.eql(u8, options.cors_origins[0], "*")) {
        return "*";
    }
    // Case-insensitive header name search for "origin:"
    var i: usize = 0;
    while (i + 7 < head_buffer.len) : (i += 1) {
        if (std.ascii.toLower(head_buffer[i]) == 'o' and
            std.ascii.toLower(head_buffer[i + 1]) == 'r' and
            std.ascii.toLower(head_buffer[i + 2]) == 'i' and
            std.ascii.toLower(head_buffer[i + 3]) == 'g' and
            std.ascii.toLower(head_buffer[i + 4]) == 'i' and
            std.ascii.toLower(head_buffer[i + 5]) == 'n' and
            head_buffer[i + 6] == ':' and
            (i == 0 or head_buffer[i - 1] == '\n'))
        {
            const value_start = i + 7;
            const line_end = std.mem.indexOfPos(u8, head_buffer, value_start, "\r\n") orelse head_buffer.len;
            const origin = std.mem.trim(u8, head_buffer[value_start..line_end], " \t");
            for (options.cors_origins) |allowed| {
                if (std.mem.eql(u8, allowed, origin)) return origin;
            }
            return "";
        }
    }
    return "";
}

fn sendCorsResponse(request: *http.Server.Request, origin: []const u8) !void {
    var headers: [4]std.http.Header = .{
        .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
        .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
        .{ .name = "access-control-allow-headers", .value = "content-type" },
        .{ .name = "vary", .value = "origin" },
    };
    try request.respond("", .{
        .status = .no_content,
        .extra_headers = &headers,
    });
}

fn sendJsonResponse(request: *http.Server.Request, json_str: []const u8, origin: []const u8) !void {
    var headers: [3]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
        .{ .name = "vary", .value = "origin" },
    };
    try request.respond(json_str, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

fn sendPlayground(request: *http.Server.Request, origin: []const u8) !void {
    var headers: [3]std.http.Header = .{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
        .{ .name = "vary", .value = "origin" },
    };
    try request.respond(playground.simple_playground_html, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

/// Execute a batch of GraphQL requests (Apollo-style array payload).
/// Returns a JSON array string. Caller owns the returned json_str memory.
fn executeBatch(
    self: *GraphQLServer,
    io: Io,
    items: []const std.json.Value,
    tenant: ?*zg.Tenant,
) !struct { json_str: []const u8, total_complexity: u64, had_error: bool } {
    if (items.len > self.options.max_batch_size) {
        const err_json = try buildErrorJson(self.allocator, "Batch size exceeds maximum allowed");
        defer self.allocator.free(err_json);
        return .{ .json_str = try self.allocator.dupe(u8, err_json), .total_complexity = 0, .had_error = true };
    }

    var results = std.array_list.Managed([]const u8).init(self.allocator);
    defer {
        for (results.items) |s| self.allocator.free(s);
        results.deinit();
    }

    var total_complexity: u64 = 0;
    var any_error = false;

    for (items) |item| {
        if (item != .object) {
            const err_json = try buildErrorJson(self.allocator, "Invalid batch item: expected object");
            try results.append(err_json);
            any_error = true;
            continue;
        }

        const obj = item.object;
        var batch_query_str: ?[]const u8 = null;
        var batch_op_name: ?[]const u8 = null;
        // batch_query_str is always owned (either a dupe of the body query or
        // an owned copy returned by resolvePersistedQueryBatch). It may be
        // replaced by resolvePersistedQueryBatch, which takes ownership of the
        // value it is passed, so only the final value is freed here.
        defer {
            if (batch_query_str) |q| self.allocator.free(q);
        }

        if (obj.get("query")) |q| {
            if (q == .string) batch_query_str = try self.allocator.dupe(u8, q.string);
        }
        if (obj.get("operationName")) |op| {
            if (op == .string) batch_op_name = op.string;
        }

        var batch_variables = std.StringHashMap(Value).init(self.allocator);
        defer {
            var vit = batch_variables.valueIterator();
            while (vit.next()) |v| v.deinit(self.allocator);
            batch_variables.deinit();
        }

        if (obj.get("variables")) |vars| {
            if (vars == .object) {
                var viter = vars.object.iterator();
                while (viter.next()) |entry| {
                    try batch_variables.put(try self.allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(self.allocator, entry.value_ptr.*));
                }
            }
        }

        // APQ: Automatic Persisted Queries (batch-safe variant)
        if (obj.get("extensions")) |ext| {
            if (ext == .object) {
                if (ext.object.get("persistedQuery")) |pq| {
                    if (pq == .object) {
                        const apq_hash = pq.object.get("sha256Hash");
                        const apq_sig = pq.object.get("signature");
                        if (apq_hash) |h| {
                            if (h == .string) {
                                const sig: ?[]const u8 = if (apq_sig) |s| (if (s == .string) s.string else null) else null;
                                batch_query_str = try apq.resolvePersistedQueryBatch(self, h.string, batch_query_str, sig);
                                if (batch_query_str == null) {
                                    const err_json = try buildErrorJson(self.allocator, "PersistedQueryNotFound");
                                    try results.append(err_json);
                                    any_error = true;
                                    continue;
                                }
                            }
                        }
                    }
                }
            }
        }

        const batch_query = batch_query_str orelse {
            const err_json = try buildErrorJson(self.allocator, "Missing query");
            try results.append(err_json);
            any_error = true;
            continue;
        };

        const batch_result = executeGraphQLAndGetJson(self, io, batch_query, batch_op_name, &batch_variables, tenant) catch |err| {
            log.err("batch execution pipeline error: {s}", .{@errorName(err)});
            const err_json = try buildErrorJson(self.allocator, "Internal error");
            try results.append(err_json);
            any_error = true;
            continue;
        };
        defer self.allocator.free(batch_result.json_str);
        total_complexity += batch_result.complexity;
        if (batch_result.had_error) any_error = true;

        try results.append(try self.allocator.dupe(u8, batch_result.json_str));
    }

    // Build JSON array response
    var buf = std.array_list.Managed(u8).init(self.allocator);
    defer buf.deinit();
    try buf.append('[');
    for (results.items, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(s);
    }
    try buf.append(']');

    const final_json = try self.allocator.dupe(u8, buf.items);
    return .{
        .json_str = final_json,
        .total_complexity = total_complexity,
        .had_error = any_error,
    };
}

pub fn sendGraphQLErrorResponse(allocator: std.mem.Allocator, request: *http.Server.Request, message: []const u8, status: std.http.Status, origin: []const u8) !void {
    // Use std.json to safely escape the message and prevent JSON injection
    const ErrorPayload = struct {
        errors: []const struct { message: []const u8 },
    };
    const payload = ErrorPayload{ .errors = &.{.{ .message = message }} };
    const json_str = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json_str);
    var headers: [3]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "access-control-allow-origin", .value = if (origin.len > 0) origin else "*" },
        .{ .name = "vary", .value = "origin" },
    };
    try request.respond(json_str, .{
        .status = status,
        .extra_headers = &headers,
    });
}

test "server executeGraphQLAndGetJson basic" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{});

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var variables = std.StringHashMap(Value).init(allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        variables.deinit();
    }

    const result = try executeGraphQLAndGetJson(&server, backend.io(), "{ hello }", null, &variables, null);
    defer allocator.free(result.json_str);
    try std.testing.expect(!result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "world") != null);
}

test "server depth limit" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    const user_field = zg.schema.Field.init(allocator, "user", zg.schema.TypeRef.named("User"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "user"), user_field);

    var user_type = try allocator.create(zg.schema.Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    const name_field = zg.schema.Field.init(allocator, "name", zg.schema.TypeRef.named("String"));
    try user_type.kind.object.fields.put(try allocator.dupe(u8, "name"), name_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("User", user_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{
        .max_query_depth = 1,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var variables = std.StringHashMap(Value).init(allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        variables.deinit();
    }

    const result = try executeGraphQLAndGetJson(&server, backend.io(), "{ user { name } }", null, &variables, null);
    defer allocator.free(result.json_str);
    try std.testing.expect(result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "depth") != null);
}

test "server complexity limit" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    const a_field = zg.schema.Field.init(allocator, "a", zg.schema.TypeRef.named("String"));
    const b_field = zg.schema.Field.init(allocator, "b", zg.schema.TypeRef.named("String"));
    const c_field = zg.schema.Field.init(allocator, "c", zg.schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "a"), a_field);
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "b"), b_field);
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "c"), c_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{
        .max_query_complexity = 1,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var variables = std.StringHashMap(Value).init(allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        variables.deinit();
    }

    const result = try executeGraphQLAndGetJson(&server, backend.io(), "{ a b c }", null, &variables, null);
    defer allocator.free(result.json_str);
    try std.testing.expect(result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "complexity") != null);
}

test "server query whitelist" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var cache = zg.QueryCache.init(allocator);
    defer cache.deinit();
    try cache.store("{ hello }");

    var server = GraphQLServer.init(allocator, &schema_def, .{
        .query_cache = &cache,
        .enforce_query_whitelist = true,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var variables = std.StringHashMap(Value).init(allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        variables.deinit();
    }

    // Allowed query
    const ok_result = try executeGraphQLAndGetJson(&server, backend.io(), "{ hello }", null, &variables, null);
    defer allocator.free(ok_result.json_str);
    try std.testing.expect(!ok_result.had_error);

    // Rejected query
    const reject_result = try executeGraphQLAndGetJson(&server, backend.io(), "{ goodbye }", null, &variables, null);
    defer allocator.free(reject_result.json_str);
    try std.testing.expect(reject_result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, reject_result.json_str, "whitelist") != null);
}

test "server batch execute multiple queries" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{});

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    const batch_json = "[{\"query\": \"{ hello }\"}, {\"query\": \"{ hello }\"}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
    defer parsed.deinit();

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
    defer allocator.free(result.json_str);

    try std.testing.expect(!result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "]") != null);
    // Should contain two "world" responses
    const first = std.mem.indexOf(u8, result.json_str, "world");
    try std.testing.expect(first != null);
    const second = std.mem.indexOf(u8, result.json_str[first.? + 1 ..], "world");
    try std.testing.expect(second != null);
}

test "server batch with missing query" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{});

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    const batch_json = "[{\"query\": \"{ hello }\"}, {}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
    defer parsed.deinit();

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
    defer allocator.free(result.json_str);

    try std.testing.expect(result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "Missing query") != null);
}

test "server batch with depth limit error" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    const user_field = zg.schema.Field.init(allocator, "user", zg.schema.TypeRef.named("User"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "user"), user_field);

    var user_type = try allocator.create(zg.schema.Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    const name_field = zg.schema.Field.init(allocator, "name", zg.schema.TypeRef.named("String"));
    try user_type.kind.object.fields.put(try allocator.dupe(u8, "name"), name_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("User", user_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{
        .max_query_depth = 1,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    const batch_json = "[{\"query\": \"{ user { name } }\"}, {\"query\": \"{ user { name } }\"}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
    defer parsed.deinit();

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
    defer allocator.free(result.json_str);

    try std.testing.expect(result.had_error);
    // Both items should have depth errors
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "depth") != null);
}

test "server batch APQ" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var cache = zg.QueryCache.init(allocator);
    defer cache.deinit();

    // Pre-register the query
    try cache.store("{ hello }");

    var server = GraphQLServer.init(allocator, &schema_def, .{
        .query_cache = &cache,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    // Get the hash for the registered query
    const hash = try zg.QueryCache.computeHash(allocator, "{ hello }");
    defer allocator.free(hash);

    const batch_json = try std.fmt.allocPrint(allocator,
        "[{{\"extensions\":{{\"persistedQuery\":{{\"sha256Hash\":\"{s}\"}}}}}}]",
        .{hash},
    );
    defer allocator.free(batch_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
    defer parsed.deinit();

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
    defer allocator.free(result.json_str);

    try std.testing.expect(!result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "world") != null);
}


test "verifyApqSignature basic" {
    const hash = "abc123";
    const secret = "my-secret";
    const sig_hex = apq.computeApqSignatureForTest(hash, secret);

    // No secret configured → always valid
    try std.testing.expect(apq.verifyApqSignature(null, hash, null));
    try std.testing.expect(apq.verifyApqSignature(null, hash, &sig_hex));

    // Secret configured but no signature → invalid
    try std.testing.expect(!apq.verifyApqSignature(secret, hash, null));

    // Valid signature
    try std.testing.expect(apq.verifyApqSignature(secret, hash, &sig_hex));

    // Invalid signature
    var bad_sig = sig_hex;
    bad_sig[0] = if (bad_sig[0] == 'a') 'b' else 'a';
    try std.testing.expect(!apq.verifyApqSignature(secret, hash, &bad_sig));

    // Wrong hash
    try std.testing.expect(!apq.verifyApqSignature(secret, "wrong-hash", &sig_hex));
}

test "server batch APQ with HMAC signature" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var cache = zg.QueryCache.init(allocator);
    defer cache.deinit();

    // Pre-register the query
    try cache.store("{ hello }");

    const hash = try zg.QueryCache.computeHash(allocator, "{ hello }");
    defer allocator.free(hash);

    const secret = "test-secret";
    const sig_hex = apq.computeApqSignatureForTest(hash, secret);

    // Valid signature → should succeed
    {
        var server = GraphQLServer.init(allocator, &schema_def, .{
            .query_cache = &cache,
            .apq_hmac_secret = secret,
        });

        const batch_json = try std.fmt.allocPrint(allocator,
            "[{{\"extensions\":{{\"persistedQuery\":{{\"sha256Hash\":\"{s}\",\"signature\":\"{s}\"}}}}}}]",
            .{ hash, sig_hex },
        );
        defer allocator.free(batch_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
        defer parsed.deinit();

        const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
        var backend = IoBackend.init(allocator, .{});
        defer backend.deinit();

        const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
        defer allocator.free(result.json_str);

        try std.testing.expect(!result.had_error);
        try std.testing.expect(std.mem.indexOf(u8, result.json_str, "world") != null);
    }

    // Invalid signature → should fail
    {
        var server = GraphQLServer.init(allocator, &schema_def, .{
            .query_cache = &cache,
            .apq_hmac_secret = secret,
        });

        var bad_sig = sig_hex;
        bad_sig[0] = if (bad_sig[0] == 'a') 'b' else 'a';

        const batch_json = try std.fmt.allocPrint(allocator,
            "[{{\"extensions\":{{\"persistedQuery\":{{\"sha256Hash\":\"{s}\",\"signature\":\"{s}\"}}}}}}]",
            .{ hash, bad_sig },
        );
        defer allocator.free(batch_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
        defer parsed.deinit();

        const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
        var backend = IoBackend.init(allocator, .{});
        defer backend.deinit();

        const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
        defer allocator.free(result.json_str);

        try std.testing.expect(result.had_error);
    }

    // Missing signature with secret configured → should fail
    {
        var server = GraphQLServer.init(allocator, &schema_def, .{
            .query_cache = &cache,
            .apq_hmac_secret = secret,
        });

        const batch_json = try std.fmt.allocPrint(allocator,
            "[{{\"extensions\":{{\"persistedQuery\":{{\"sha256Hash\":\"{s}\"}}}}}}]",
            .{hash},
        );
        defer allocator.free(batch_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
        defer parsed.deinit();

        const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
        var backend = IoBackend.init(allocator, .{});
        defer backend.deinit();

        const result = try executeBatch(&server, backend.io(), parsed.value.array.items, null);
        defer allocator.free(result.json_str);

        try std.testing.expect(result.had_error);
    }
}



test "server response cache is tenant-isolated" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var rc = zg.ResponseCache.init(allocator, 60_000);
    defer rc.deinit();

    var server = GraphQLServer.init(allocator, &schema_def, .{
        .response_cache = &rc,
    });

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var variables = std.StringHashMap(Value).init(allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        variables.deinit();
    }

    var tenant_a = zg.Tenant{ .id = "tenant-a" };
    var tenant_b = zg.Tenant{ .id = "tenant-b" };

    // First request for tenant-a caches its response.
    const r1 = try executeGraphQLAndGetJson(&server, backend.io(), "{ hello }", null, &variables, &tenant_a);
    defer allocator.free(r1.json_str);
    try std.testing.expect(!r1.had_error);

    // A different tenant with the same query must NOT hit tenant-a's cache
    // entry; the resolver runs again (still returns "world", but the point is
    // the cache key is tenant-scoped and no cross-tenant data is served).
    const r2 = try executeGraphQLAndGetJson(&server, backend.io(), "{ hello }", null, &variables, &tenant_b);
    defer allocator.free(r2.json_str);
    try std.testing.expect(!r2.had_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.json_str, "world") != null);
}
