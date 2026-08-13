# Deployment Guide

## Quick Deployment

```zig
const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
var backend = IoBackend.init(allocator, .{});
defer backend.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .bind_address = std.Io.net.IpAddress.parseIp4("0.0.0.0", 8080) catch unreachable,
    .max_query_depth = 20,
    .max_query_complexity = 1000,
    .max_body_size = 1024 * 1024,
    .max_connections = 10000,
});

try server.listen(backend.io());
```

## Production Checklist

### 1. Resource Limits

| Option | Recommended | Description |
|--------|-------------|-------------|
| `max_query_depth` | `15` | Prevents deeply nested DoS queries. |
| `max_query_complexity` | `1000` | Rejects overly complex queries. |
| `max_body_size` | `1_048_576` (1MB) | Limits request body size. |
| `max_connections` | `10000` | Connection limit to prevent FD exhaustion. |
| `max_batch_size` | `10` | Limits batch query array length. |
| `max_alias_count` | `100` | Prevents alias abuse. |
| `read_timeout_ms` | `30000` (30s) | Drops slow clients. |

### 2. Security

**Persisted Queries (Recommended)**
```zig
var cache = zg.QueryCache.init(allocator);
defer cache.deinit();
try cache.store("{ hello }");

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .query_cache = &cache,
    .enforce_query_whitelist = true,
});
```

**Rate Limiting**
```zig
var rate_limiter = zg.RateLimiter.init(allocator, 1000, 100);
defer rate_limiter.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .rate_limiter = &rate_limiter,
});
```

**Field-Level Authorization**
```zig
const hooks = zg.ExecutionHooks{
    .hasRole = struct {
        fn hook(ctx: ?*anyopaque, role: []const u8) bool {
            const session = @as(*Session, @ptrCast(@alignCast(ctx.?)));
            return session.hasRole(role);
        }
    }.hook,
};
```

Set `.required_role` on schema fields to enforce:
```zig
field.required_role = "admin";
```

### 3. Observability

**Metrics**
```zig
var metrics = zg.MetricsCollector.init(allocator);
defer metrics.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .metrics = &metrics,
});

// Access via /graphql/metrics
```

**Distributed Tracing**
```zig
var tracer = zg.Tracer.init(allocator, io);
defer tracer.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .tracer = &tracer,
});
```

**Audit Logging**
```zig
var audit = try zg.AuditLog.init(allocator, io, "/var/log/graphql.jsonl");
defer audit.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .audit_log = &audit,
});
```

### 4. Reverse Proxy

For TLS termination and load balancing, place `zgraphql` behind a reverse proxy:

```nginx
# nginx example
server {
    listen 443 ssl http2;
    server_name api.example.com;

    location /graphql {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
```

Use `.bind_unix_path` for Unix domain socket communication with the proxy:

```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .bind_unix_path = "/run/zgraphql.sock",
});
```

### 5. Graceful Shutdown

The server handles `SIGINT` and `SIGTERM` automatically. Active requests are drained before exit.

```bash
# Send SIGTERM for graceful shutdown
kill -TERM $(pidof my-zgraphql-app)
```

### 6. Multi-Tenant Considerations

zgraphql provides built-in tenant isolation via `TenantManager` (see Section 8 below). Each tenant can have its own schema override, query depth/complexity limits, body size limit, rate limiter, and query whitelist. For additional isolation:

- **Option A**: Run one `zgraphql` instance per tenant, routed by a gateway.
- **Option B**: Use a single instance with resolver-level tenant filtering via `ExecutionContext.user_data`.

### 7. Distributed Cache (Multi-Node)

For multi-node deployments, use `DistributedCache` with an HTTP cache backend:

```zig
var http_backend = try zg.HttpCacheBackend.init(allocator, io, "http://cache-proxy:8080");
defer http_backend.deinit();

var dc = zg.DistributedCache.init(
    allocator,
    http_backend.cacheBackend(),
    "zgraphql:",
    &response_cache, // L1 local cache
);
defer dc.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .response_cache = &response_cache,
    .distributed_cache = &dc,
});
```

The cache proxy can be Varnish, Nginx with cache, or a custom lightweight cache service. The expected REST API:
- `GET /{key}` -> 200 with body or 404
- `PUT /{key}?ttl={ms}` -> store body with TTL
- `DELETE /{key}` -> remove entry

For Redis, implement the `CacheBackend` interface using a RESP client.

### 8. Tenant Isolation (Multi-Tenant)

Register tenants with independent limits:

```zig
var tm = zg.TenantManager.init(allocator);
defer tm.deinit();

try tm.register(.{
    .id = "tenant-a",
    .max_query_depth = 10,
    .max_query_complexity = 500,
    .max_body_size = 512 * 1024,
    .enforce_query_whitelist = true,
});

try tm.register(.{
    .id = "tenant-b",
    .max_query_depth = 20,
    .rate_limiter = &tenant_b_limiter,
});

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .tenant_manager = &tm,
});
```

Tenants are resolved via the `X-Tenant-ID` header by default. Each request is subject to the tenant's configured limits. If no tenant matches and no default tenant is set, the global server options are used.

### 9. Playground

Enable the built-in GraphQL IDE for development:

```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .enable_playground = true,
});
```

Navigate to `http://localhost:8080/graphql/playground`.

- **Offline mode** (default): a zero-dependency minimal playground with query editing, variable input, response formatting, and introspection.
- **CDN mode**: replace the HTML with `graphiql_html` in `server.zig` to serve GraphiQL via CDN.

**Disable in production** to reduce attack surface:
```zig
.enable_playground = false, // default
```

### 10. Horizontal Scaling

For high-traffic scenarios, run multiple `zgraphql` processes behind a load balancer:

- Use `DistributedCache` with an HTTP cache backend for shared query results across nodes.
- Store `QueryCache` (APQ whitelist) in a shared KV store.
- Stateless design makes scaling straightforward.
