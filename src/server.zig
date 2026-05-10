const std = @import("std");
const zg = @import("zgraphql.zig");
const Schema = zg.schema.Schema;
const Value = zg.Value;
const Io = std.Io;
const net = Io.net;
const http = std.http;

const log = std.log.scoped(.zgraphql_server);

/// Maximum number of concurrent server instances that can register for signal handling.
const max_server_instances = 16;

/// Registered server instances for graceful shutdown signal handling.
var g_server_registry: [max_server_instances]?*GraphQLServer = .{null} ** max_server_instances;
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
    const signame = switch (sig) {
        std.posix.SIG.INT => "SIGINT",
        std.posix.SIG.TERM => "SIGTERM",
        else => "unknown",
    };
    log.info("received {s}, initiating graceful shutdown for all registered instances", .{signame});
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
            log.info("shutdown complete", .{});
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

    // WebSocket upgrade
    const upgrade = request.upgradeRequested();
    if (upgrade == .websocket) {
        const key = upgrade.websocket orelse {
            try sendGraphQLErrorResponse(self.allocator, request, "Missing Sec-WebSocket-Key", .bad_request, origin);
            return;
        };
        var ws = try request.respondWebSocket(.{ .key = key });
        try ws.output.flush();
        try handleWebSocket(self, io, &ws);
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

    // Tenant resolution
    var resolved_tenant: ?*zg.Tenant = null;
    if (self.options.tenant_manager) |tm| {
        resolved_tenant = tm.resolve(request.head_buffer);
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
            entry.value_ptr.deinit();
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
            const batch_result = try executeBatch(self, io, root.array.items);
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
            if (q == .string) query_str = q.string;
        }
        if (obj.get("operationName")) |op| {
            if (op == .string) operation_name = op.string;
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
                                query_str = try resolvePersistedQuery(self, request, h.string, query_str, sig, origin);
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
                    query_str = val;
                } else if (std.mem.eql(u8, key, "operationName")) {
                    operation_name = val;
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
                                        query_str = try resolvePersistedQuery(self, request, h.string, query_str, sig, origin);
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

/// Execute a GraphQL query string and return the JSON response.
/// Caller owns the returned json_str memory.
fn executeGraphQLAndGetJson(
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

    // Response cache check (only for queries without runtime variables)
    const cacheable = variables.count() == 0;
    if (cacheable) {
        // Check distributed cache (L2) first
        if (self.options.distributed_cache) |dc| {
            const now_ts = Io.Clock.Timestamp.now(io, .real);
            const now_ms: i64 = @intCast(@divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms));
            if (try dc.get(query, now_ms)) |cached| {
                return .{ .json_str = cached, .complexity = 0, .had_error = false };
            }
        }
        // Check local response cache (L1)
        if (self.options.response_cache) |cache| {
            const now_ts = Io.Clock.Timestamp.now(io, .real);
            const now_ms: i64 = @intCast(@divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms));
            if (cache.get(query, now_ms)) |cached| {
                return .{ .json_str = try self.allocator.dupe(u8, cached), .complexity = 0, .had_error = false };
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
        errdefer error_json.deinit();
        var errors = Value.initList(self.allocator);
        defer errors.deinit();
        for (validation_result.errors.items) |err| {
            var err_obj = Value.initObject(self.allocator);
            try err_obj.data.object.put(try self.allocator.dupe(u8, "message"), Value.fromString(self.allocator, try self.allocator.dupe(u8, err.message)));
            if (err.line != null or err.col != null) {
                var loc = Value.initObject(self.allocator);
                if (err.line) |line| {
                    try loc.data.object.put(try self.allocator.dupe(u8, "line"), Value.fromInt(self.allocator, @intCast(line)));
                }
                if (err.col) |col| {
                    try loc.data.object.put(try self.allocator.dupe(u8, "column"), Value.fromInt(self.allocator, @intCast(col)));
                }
                var locations = Value.initList(self.allocator);
                try locations.data.list.append(loc);
                try err_obj.data.object.put(try self.allocator.dupe(u8, "locations"), locations);
            }
            try errors.data.list.append(err_obj);
        }
        try error_json.data.object.put(try self.allocator.dupe(u8, "errors"), errors);
        const json_str = error_json.toJson() catch |err| {
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
        return .{
            .json_str = try buildErrorJson(self.allocator, "Execution error"),
            .complexity = complexity,
            .had_error = true,
        };
    };
    defer result.deinit();

    const json_str = result.toJson() catch |err| {
        log.err("json serialization error: {s}", .{@errorName(err)});
        return error.OutOfMemory;
    };

    // Store successful cacheable response
    if (cacheable) {
        const now_ts = Io.Clock.Timestamp.now(io, .real);
        const now_ms: i64 = @intCast(@divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms));
        // Store to distributed cache (L2)
        if (self.options.distributed_cache) |dc| {
            dc.setWithDefaultTtl(query, json_str, now_ms) catch |err| {
                log.warn("failed to store to distributed cache: {s}", .{@errorName(err)});
            };
        }
        // Store to local response cache (L1)
        if (self.options.response_cache) |cache| {
            cache.put(query, json_str, now_ms) catch |err| {
                log.warn("failed to cache response: {s}", .{@errorName(err)});
            };
        }
    }

    return .{ .json_str = json_str, .complexity = complexity, .had_error = false };
}

fn buildErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const ErrorPayload = struct {
        errors: []const struct { message: []const u8 },
    };
    const payload = ErrorPayload{ .errors = &.{.{ .message = message }} };
    return try std.json.Stringify.valueAlloc(allocator, payload, .{});
}

fn jsonToGraphQLValue(allocator: std.mem.Allocator, json_val: std.json.Value) std.mem.Allocator.Error!Value {
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
            errdefer list.deinit();
            for (arr.items) |item| {
                try list.data.list.append(try jsonToGraphQLValue(allocator, item));
            }
            return list;
        },
        .object => |obj| {
            var graph_obj = Value.initObject(allocator);
            errdefer graph_obj.deinit();
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try graph_obj.data.object.put(try allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(allocator, entry.value_ptr.*));
            }
            return graph_obj;
        },
    }
}

fn readRequestBody(allocator: std.mem.Allocator, request: *http.Server.Request) ![]u8 {
    const len = request.head.content_length orelse return "";
    if (len == 0) return "";

    const body = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(body);

    var transfer_buffer: [4096]u8 = undefined;
    const body_reader = request.server.reader.bodyReader(
        &transfer_buffer,
        request.head.transfer_encoding,
        request.head.content_length,
    );

    var writer = Io.Writer.fixed(body);
    try body_reader.streamExact(&writer, @intCast(len));

    return body;
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
    try request.respond(simple_playground_html, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}

/// Verify an APQ signature using HMAC-SHA256.
/// `signature` must be a lower-case hex string of the HMAC.
/// Returns true if the signature is valid or no secret is configured.
fn verifyApqSignature(secret: ?[]const u8, hash: []const u8, signature: ?[]const u8) bool {
    const s = secret orelse return true;
    const sig = signature orelse return false;

    var mac_bytes: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_bytes, hash, s);
    const expected_hex = std.fmt.bytesToHex(mac_bytes, .lower);

    if (sig.len != expected_hex.len) return false;
    var diff: u8 = 0;
    for (sig, expected_hex) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

/// Resolve an APQ (Automatic Persisted Query) hash.
/// Returns the query string to execute, or null if an error response was already sent.
fn resolvePersistedQuery(self: *GraphQLServer, request: *http.Server.Request, hash: []const u8, provided_query: ?[]const u8, signature: ?[]const u8, origin: []const u8) !?[]const u8 {
    if (!verifyApqSignature(self.options.apq_hmac_secret, hash, signature)) {
        try sendGraphQLErrorResponse(self.allocator, request, "PersistedQuery.InvalidSignature", .bad_request, origin);
        return null;
    }

    const cache = self.options.query_cache orelse {
        // No cache configured; if whitelist is on, reject
        if (self.options.enforce_query_whitelist) {
            try sendGraphQLErrorResponse(self.allocator, request, "PersistedQueryNotFound", .ok, origin);
            return null;
        }
        return provided_query;
    };

    if (cache.getInsensitive(hash)) |cached_query| {
        return cached_query;
    }

    if (provided_query) |query| {
        // Verify the hash matches the provided query (case-insensitive)
        const computed = try zg.QueryCache.computeHash(self.allocator, query);
        defer self.allocator.free(computed);
        const hash_match = std.mem.eql(u8, computed, hash) or blk: {
            const lower_hash = try self.allocator.alloc(u8, hash.len);
            defer self.allocator.free(lower_hash);
            _ = std.ascii.lowerString(lower_hash, hash);
            break :blk std.mem.eql(u8, computed, lower_hash);
        };
        if (!hash_match) {
            try sendGraphQLErrorResponse(self.allocator, request, "Provided sha does not match query", .bad_request, origin);
            return null;
        }

        // In whitelist mode, don't auto-register new queries
        if (!self.options.enforce_query_whitelist) {
            try cache.store(query);
        }
        return query;
    }

    // Hash not found and no query provided
    try sendGraphQLErrorResponse(self.allocator, request, "PersistedQueryNotFound", .ok, origin);
    return null;
}

/// Batch-safe variant of resolvePersistedQuery that does not send HTTP responses.
/// Returns null on any APQ failure (caller should produce a GraphQL error JSON).
fn resolvePersistedQueryBatch(self: *GraphQLServer, hash: []const u8, provided_query: ?[]const u8, signature: ?[]const u8) !?[]const u8 {
    if (!verifyApqSignature(self.options.apq_hmac_secret, hash, signature)) {
        return null;
    }

    const cache = self.options.query_cache orelse {
        if (self.options.enforce_query_whitelist) return null;
        return provided_query;
    };

    if (cache.getInsensitive(hash)) |cached_query| {
        return cached_query;
    }

    if (provided_query) |query| {
        const computed = try zg.QueryCache.computeHash(self.allocator, query);
        defer self.allocator.free(computed);
        const hash_match = std.mem.eql(u8, computed, hash) or blk: {
            const lower_hash = try self.allocator.alloc(u8, hash.len);
            defer self.allocator.free(lower_hash);
            _ = std.ascii.lowerString(lower_hash, hash);
            break :blk std.mem.eql(u8, computed, lower_hash);
        };
        if (!hash_match) return null;

        if (!self.options.enforce_query_whitelist) {
            try cache.store(query);
        }
        return query;
    }

    return null;
}

/// Execute a batch of GraphQL requests (Apollo-style array payload).
/// Returns a JSON array string. Caller owns the returned json_str memory.
fn executeBatch(
    self: *GraphQLServer,
    io: Io,
    items: []const std.json.Value,
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

        if (obj.get("query")) |q| {
            if (q == .string) batch_query_str = q.string;
        }
        if (obj.get("operationName")) |op| {
            if (op == .string) batch_op_name = op.string;
        }

        var batch_variables = std.StringHashMap(Value).init(self.allocator);
        defer {
            var vit = batch_variables.valueIterator();
            while (vit.next()) |v| v.deinit();
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
                                batch_query_str = try resolvePersistedQueryBatch(self, h.string, batch_query_str, sig);
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

        const batch_result = executeGraphQLAndGetJson(self, io, batch_query, batch_op_name, &batch_variables, null) catch |err| {
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

fn sendGraphQLErrorResponse(allocator: std.mem.Allocator, request: *http.Server.Request, message: []const u8, status: std.http.Status, origin: []const u8) !void {
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

fn readPayloadLen(in: *std.Io.Reader, h1: std.http.Server.WebSocket.Header1) !usize {
    return switch (h1.payload_len) {
        .len16 => try in.takeInt(u16, .big),
        .len64 => std.math.cast(usize, try in.takeInt(u64, .big)) orelse return error.MessageOversize,
        else => @intFromEnum(h1.payload_len),
    };
}

/// Read a WebSocket message, supporting fragmented frames and payloads larger
/// than the input buffer. Caller owns the returned memory.
fn readWebSocketMessage(allocator: std.mem.Allocator, ws: *http.Server.WebSocket, max_size: usize) !?[]u8 {
    const in = ws.input;

    var opcode: ?std.http.Server.WebSocket.Opcode = null;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    while (true) {
        const header = try in.takeArray(2);
        const h0: std.http.Server.WebSocket.Header0 = @bitCast(header[0]);
        const h1: std.http.Server.WebSocket.Header1 = @bitCast(header[1]);

        switch (h0.opcode) {
            .text, .binary, .pong, .ping => {},
            .connection_close => return error.ConnectionClose,
            .continuation => {},
            _ => return error.UnexpectedOpCode,
        }

        if (!h1.mask) return error.MissingMaskBit;

        const plen = try readPayloadLen(in, h1);
        const mask: u32 = @bitCast((try in.takeArray(4)).*);

        // Handle control frames inline
        if (h0.opcode == .ping) {
            const ping_buf = try allocator.alloc(u8, plen);
            defer allocator.free(ping_buf);
            try in.readSliceAll(ping_buf);
            try ws.writeMessage(ping_buf, .pong);
            continue;
        }
        if (h0.opcode == .pong) {
            const pong_buf = try allocator.alloc(u8, plen);
            defer allocator.free(pong_buf);
            try in.readSliceAll(pong_buf);
            continue;
        }

        // Read payload
        var payload: []u8 = undefined;
        var owned = false;
        if (plen > in.buffer.len) {
            payload = try allocator.alloc(u8, plen);
            owned = true;
            try in.readSliceAll(payload);
        } else {
            payload = try in.take(plen);
        }

        // Unmask payload
        const floored_len = (payload.len / 4) * 4;
        const u32_payload: []align(1) u32 = @ptrCast(payload[0..floored_len]);
        for (u32_payload) |*elem| elem.* ^= mask;
        const mask_bytes: []const u8 = @ptrCast(&mask);
        for (payload[floored_len..], mask_bytes[0 .. payload.len - floored_len]) |*leftover, m|
            leftover.* ^= m;

        if (opcode == null) {
            if (h0.opcode == .continuation) return error.UnexpectedOpCode;
            opcode = h0.opcode;
        }

        try buf.appendSlice(payload);
        if (buf.items.len > max_size) {
            if (owned) allocator.free(payload);
            return error.MessageTooLarge;
        }
        if (owned) allocator.free(payload);

        if (h0.fin) break;
    }

    if (buf.items.len == 0) return null;
    return try allocator.dupe(u8, buf.items);
}

const ActiveSubscription = struct {
    stream: zg.schema.SubscriptionStream,
    future: Io.Future(Io.Cancelable!void),
    id: []const u8,
};

/// Consume a subscription stream in a concurrent task, sending events over WebSocket.
fn consumeSubscription(
    self: *GraphQLServer,
    io: Io,
    ws: *http.Server.WebSocket,
    ws_mutex: *std.Io.Mutex,
    stream: zg.schema.SubscriptionStream,
    id: []const u8,
) Io.Cancelable!void {
    defer stream.deinit(self.allocator);
    while (true) {
        io.checkCancel() catch return;

        var event = stream.next(self.allocator) catch |err| {
            log.err("subscription stream error: {s}", .{@errorName(err)});
            const err_json = buildErrorJson(self.allocator, "Subscription stream error") catch break;
            defer self.allocator.free(err_json);
            const response = std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json }) catch break;
            defer self.allocator.free(response);
            ws_mutex.lock(io) catch break;
            defer ws_mutex.unlock(io);
            ws.writeMessage(response, .text) catch |werr| {
                log.err("websocket write error (subscription error): {s}", .{@errorName(werr)});
            };
            break;
        } orelse break;
        defer event.deinit();

        const json_str = event.toJson() catch {
            log.err("subscription json serialization failed", .{});
            break;
        };
        defer self.allocator.free(json_str);

        const response = std.fmt.allocPrint(self.allocator, "{{\"type\":\"next\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, json_str }) catch break;
        defer self.allocator.free(response);

        ws_mutex.lock(io) catch break;
        defer ws_mutex.unlock(io);
        ws.writeMessage(response, .text) catch |werr| {
            log.err("websocket write error (subscription next): {s}", .{@errorName(werr)});
        };
    }

    // Send complete
    const complete_response = std.fmt.allocPrint(self.allocator, "{{\"type\":\"complete\",\"id\":\"{s}\"}}", .{id}) catch return;
    defer self.allocator.free(complete_response);
    ws_mutex.lock(io) catch return;
    defer ws_mutex.unlock(io);
    ws.writeMessage(complete_response, .text) catch |werr| {
        log.err("websocket write error (subscription complete): {s}", .{@errorName(werr)});
    };

    stream.deinit(self.allocator);
}

/// Handle WebSocket connection using graphql-ws protocol.
fn handleWebSocket(self: *GraphQLServer, io: Io, ws: *http.Server.WebSocket) !void {
    // Wait for connection_init
    const init_msg_data = readWebSocketMessage(self.allocator, ws, self.options.max_websocket_message_size) catch |err| switch (err) {
        error.ConnectionClose => return,
        else => {
            log.err("websocket read error: {s}", .{@errorName(err)});
            return;
        },
    };
    defer if (init_msg_data) |d| self.allocator.free(d);

    // Parse connection_init
    const init_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, init_msg_data orelse "{}", .{}) catch {
        try ws.writeMessage("{\"type\":\"connection_error\"}", .text);
        return;
    };
    defer init_parsed.deinit();

    const msg_type_ok = if (init_parsed.value.object.get("type")) |t| t == .string and std.mem.eql(u8, t.string, "connection_init") else false;
    if (init_parsed.value != .object or !msg_type_ok) {
        try ws.writeMessage("{\"type\":\"connection_error\"}", .text);
        return;
    }

    // Send connection_ack
    try ws.writeMessage("{\"type\":\"connection_ack\"}", .text);

    var ws_mutex = std.Io.Mutex.init;
    var active_subs = std.StringHashMap(ActiveSubscription).init(self.allocator);
    defer {
        // Cancel all active subscriptions on disconnect and await completion
        var iter = active_subs.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.stream.cancel();
            _ = entry.value_ptr.future.cancel(io) catch {};
            _ = entry.value_ptr.future.await(io) catch {};
            self.allocator.free(entry.value_ptr.id);
        }
        active_subs.deinit();
    }

    // Message loop
    while (true) {
        const msg_data = readWebSocketMessage(self.allocator, ws, self.options.max_websocket_message_size) catch |err| switch (err) {
            error.ConnectionClose => return,
            else => {
                log.err("websocket read error: {s}", .{@errorName(err)});
                return;
            },
        };
        defer if (msg_data) |d| self.allocator.free(d);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg_data orelse "{}", .{}) catch continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const msg_type = if (obj.get("type")) |t| (if (t == .string) t.string else continue) else continue;

        if (std.mem.eql(u8, msg_type, "ping")) {
            try ws.writeMessage("{\"type\":\"pong\"}", .text);
            continue;
        }

        if (std.mem.eql(u8, msg_type, "subscribe")) {
            const id = if (obj.get("id")) |id_val| (if (id_val == .string) id_val.string else "") else "";
            const payload = if (obj.get("payload")) |p| (if (p == .object) p else continue) else continue;

            var query_str: ?[]const u8 = null;
            var operation_name: ?[]const u8 = null;
            var variables = std.StringHashMap(Value).init(self.allocator);
            defer {
                var viter = variables.iterator();
                while (viter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit();
                }
                variables.deinit();
            }

            if (payload.object.get("query")) |q| {
                if (q == .string) query_str = q.string;
            }
            if (payload.object.get("operationName")) |op| {
                if (op == .string) operation_name = op.string;
            }
            if (payload.object.get("variables")) |vars| {
                if (vars == .object) {
                    var viter = vars.object.iterator();
                    while (viter.next()) |entry| {
                        try variables.put(try self.allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(self.allocator, entry.value_ptr.*));
                    }
                }
            }

            const query = query_str orelse {
                const err_json = try buildErrorJson(self.allocator, "Missing query");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };

            // Parse document to determine operation type
            var parser = zg.Parser.init(self.allocator, query) catch |err| {
                log.err("websocket parser init error: {s}", .{@errorName(err)});
                const err_json = try buildErrorJson(self.allocator, "Parser error");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };
            defer parser.deinit();
            var doc = parser.parseDocument() catch |err| {
                log.err("websocket parse error: {s}", .{@errorName(err)});
                const err_json = try buildErrorJson(self.allocator, "Syntax error");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };
            defer doc.deinit();

            // Detect subscription operation
            var is_subscription = false;
            for (doc.definitions.items) |*def| {
                switch (def.*) {
                    .operation => |*op| {
                        if (operation_name) |name| {
                            if (op.name != null and std.mem.eql(u8, op.name.?, name)) {
                                is_subscription = op.op_type == .subscription;
                                break;
                            }
                        } else {
                            if (!is_subscription) {
                                is_subscription = op.op_type == .subscription;
                            }
                        }
                    },
                    else => {},
                }
            }

            if (is_subscription) {
                // Cancel any existing subscription with the same ID
                if (active_subs.getPtr(id)) |existing| {
                    existing.stream.cancel();
                    _ = existing.future.cancel(io) catch {};
                    self.allocator.free(existing.id);
                    _ = active_subs.remove(id);
                }

                var executor = zg.Executor.init(self.allocator, self.schema_def, io);
                defer executor.deinit();
                try executor.setVariables(variables);
                if (self.options.hooks) |hooks| executor.hooks = hooks;

                var stream = executor.executeSubscription(&doc) catch |err| {
                    log.err("websocket subscription error: {s}", .{@errorName(err)});
                    const err_json = try buildErrorJson(self.allocator, "Subscription error");
                    defer self.allocator.free(err_json);
                    const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                    defer self.allocator.free(response);
                    try ws.writeMessage(response, .text);
                    continue;
                };
                errdefer stream.deinit(self.allocator);

                const id_copy = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(id_copy);

                const future = try Io.concurrent(io, consumeSubscription, .{ self, io, ws, &ws_mutex, stream, id_copy });

                try active_subs.put(id_copy, .{
                    .stream = stream,
                    .future = future,
                    .id = id_copy,
                });
                continue;
            }

            // Non-subscription: single-shot execution
            const result = executeGraphQLAndGetJson(self, io, query, operation_name, &variables, null) catch |err| {
                log.err("websocket execution error: {s}", .{@errorName(err)});
                const err_json = try buildErrorJson(self.allocator, "Internal error");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };
            defer self.allocator.free(result.json_str);

            // Send next with payload
            const next_response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"next\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, result.json_str });
            defer self.allocator.free(next_response);
            try ws.writeMessage(next_response, .text);

            // Send complete
            const complete_response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"complete\",\"id\":\"{s}\"}}", .{id});
            defer self.allocator.free(complete_response);
            try ws.writeMessage(complete_response, .text);
            continue;
        }

        if (std.mem.eql(u8, msg_type, "complete")) {
            const id = if (obj.get("id")) |id_val| (if (id_val == .string) id_val.string else continue) else continue;
            if (active_subs.getPtr(id)) |entry| {
                entry.stream.cancel();
                _ = entry.future.cancel(io) catch {};
                self.allocator.free(entry.id);
                _ = active_subs.remove(id);
            }
            continue;
        }
    }
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
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
            entry.value_ptr.deinit();
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
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
            entry.value_ptr.deinit();
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
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
            entry.value_ptr.deinit();
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
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
            entry.value_ptr.deinit();
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{});

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    const batch_json = "[{\"query\": \"{ hello }\"}, {\"query\": \"{ hello }\"}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
    defer parsed.deinit();

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var server = GraphQLServer.init(allocator, &schema_def, .{});

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    const batch_json = "[{\"query\": \"{ hello }\"}, {}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, batch_json, .{});
    defer parsed.deinit();

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
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

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
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

    const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
    defer allocator.free(result.json_str);

    try std.testing.expect(!result.had_error);
    try std.testing.expect(std.mem.indexOf(u8, result.json_str, "world") != null);
}


fn computeApqSignatureForTest(hash: []const u8, secret: []const u8) [std.crypto.auth.hmac.sha2.HmacSha256.mac_length * 2]u8 {
    var mac_bytes: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_bytes, hash, secret);
    return std.fmt.bytesToHex(mac_bytes, .lower);
}

test "verifyApqSignature basic" {
    const hash = "abc123";
    const secret = "my-secret";
    const sig_hex = computeApqSignatureForTest(hash, secret);

    // No secret configured → always valid
    try std.testing.expect(verifyApqSignature(null, hash, null));
    try std.testing.expect(verifyApqSignature(null, hash, &sig_hex));

    // Secret configured but no signature → invalid
    try std.testing.expect(!verifyApqSignature(secret, hash, null));

    // Valid signature
    try std.testing.expect(verifyApqSignature(secret, hash, &sig_hex));

    // Invalid signature
    var bad_sig = sig_hex;
    bad_sig[0] = if (bad_sig[0] == 'a') 'b' else 'a';
    try std.testing.expect(!verifyApqSignature(secret, hash, &bad_sig));

    // Wrong hash
    try std.testing.expect(!verifyApqSignature(secret, "wrong-hash", &sig_hex));
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var cache = zg.QueryCache.init(allocator);
    defer cache.deinit();

    // Pre-register the query
    try cache.store("{ hello }");

    const hash = try zg.QueryCache.computeHash(allocator, "{ hello }");
    defer allocator.free(hash);

    const secret = "test-secret";
    const sig_hex = computeApqSignatureForTest(hash, secret);

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

        const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
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

        const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
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

        const result = try executeBatch(&server, backend.io(), parsed.value.array.items);
        defer allocator.free(result.json_str);

        try std.testing.expect(result.had_error);
    }
}


// ------------------------------------------------------------------
// Playground HTML
// ------------------------------------------------------------------

/// Zero-dependency minimal GraphQL playground. Works offline.
const simple_playground_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>zgraphql Playground</title>
    \\  <style>
    \\    * { box-sizing: border-box; margin: 0; padding: 0; }
    \\    body { display: flex; height: 100vh; background: #1e1e1e; color: #d4d4d4; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
    \\    .pane { flex: 1; display: flex; flex-direction: column; border-right: 1px solid #333; }
    \\    .pane:last-child { border-right: none; }
    \\    h2 { padding: 8px 12px; background: #252526; font-size: 13px; font-weight: 600; border-bottom: 1px solid #333; }
    \\    textarea, pre { flex: 1; padding: 12px; background: #1e1e1e; color: #d4d4d4; border: none; resize: none; outline: none; font-size: 13px; line-height: 1.5; }
    \\    pre { overflow: auto; white-space: pre-wrap; word-break: break-word; }
    \\    button { margin: 8px 12px; padding: 6px 16px; background: #0e639c; color: #fff; border: none; cursor: pointer; font-size: 13px; border-radius: 3px; }
    \\    button:hover { background: #1177bb; }
    \\    .toolbar { display: flex; gap: 8px; padding: 8px 12px; background: #252526; border-bottom: 1px solid #333; }
    \\    .error { color: #f48771; }
    \\    .success { color: #b5cea8; }
    \\    .status { padding: 4px 12px; font-size: 12px; background: #252526; border-top: 1px solid #333; }
    \\  </style>
    \\</head>
    \\</html>
    \\<body>
    \\  <div class="pane">
    \\    <h2>Query</h2>
    \\    <textarea id="query" spellcheck="false" placeholder="Enter GraphQL query...">{ hello }</textarea>
    \\    <h2>Variables (JSON)</h2>
    \\    <textarea id="vars" spellcheck="false" placeholder="{}">{}</textarea>
    \\    <div class="toolbar">
    \\      <button onclick="send()">Execute</button>
    \\      <button onclick="introspect()">Introspect</button>
    \\      <button onclick="prettify()">Prettify</button>
    \\    </div>
    \\    <div class="status" id="status">Ready</div>
    \\  </div>
    \\  <div class="pane">
    \\    <h2>Response</h2>
    \\    <pre id="response"></pre>
    \\  </div>
    \\  <script>
    \\    async function send() {
    \\      const q = document.getElementById('query').value;
    \\      const v = document.getElementById('vars').value;
    \\      const statusEl = document.getElementById('status');
    \\      const respEl = document.getElementById('response');
    \\      statusEl.textContent = 'Loading...';
    \\      try {
    \\        const res = await fetch('/graphql', {
    \\          method: 'POST',
    \\          headers: { 'Content-Type': 'application/json' },
    \\          body: JSON.stringify({ query: q, variables: JSON.parse(v || '{}') })
    \\        });
    \\        const data = await res.json();
    \\        respEl.textContent = JSON.stringify(data, null, 2);
    \\        statusEl.textContent = res.ok ? 'OK ' + res.status : 'Error ' + res.status;
    \\        statusEl.className = res.ok ? 'status success' : 'status error';
    \\      } catch (e) {
    \\        respEl.textContent = String(e);
    \\        statusEl.textContent = 'Network Error';
    \\        statusEl.className = 'status error';
    \\      }
    \\    }
    \\    function introspect() {
    \\      document.getElementById('query').value = '{ __schema { queryType { name } mutationType { name } subscriptionType { name } types { name kind fields { name type { name kind } } } } }';
    \\      send();
    \\    }
    \\    function prettify() {
    \\      const q = document.getElementById('query').value;
    \\      document.getElementById('query').value = JSON.stringify({q:q}).slice(5,-1).replace(/\\n/g,'\n').replace(/\\t/g,'  ');
    \\    }
    \\  </script>
    \\</body>
    \\</html>
;

/// GraphiQL playground via CDN. Requires internet access.
const graphiql_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>GraphiQL</title>
    \\  <link rel="stylesheet" crossorigin href="https://unpkg.com/graphiql@3/graphiql.min.css" />
    \\  <style>body{margin:0;height:100vh;}#root{height:100vh;}</style>
    \\</head>
    \\</html>
    \\<body>
    \\  <div id="root"></div>
    \\  <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
    \\  <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
    \\  <script crossorigin src="https://unpkg.com/graphiql@3/graphiql.min.js"></script>
    \\  <script>
    \\    const fetcher = GraphiQL.createFetcher({ url: '/graphql' });
    \\    ReactDOM.createRoot(document.getElementById('root')).render(
    \\      React.createElement(GraphiQL, { fetcher: fetcher, defaultEditorToolsVisibility: true })
    \\    );
    \\  </script>
    \\</body>
    \\</html>
;
