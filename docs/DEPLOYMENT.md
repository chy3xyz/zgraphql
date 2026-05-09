# Deployment Guide 部署指南

> English below, 中文在后

## Quick Deployment 快速部署

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

## Production Checklist 生产检查清单

### 1. Resource Limits 资源限制

| Option | Recommended | Description |
|--------|-------------|-------------|
| `max_query_depth` | `15` | Prevents deeply nested DoS queries. 防止深层嵌套的 DoS 查询。 |
| `max_query_complexity` | `1000` | Rejects overly complex queries. 拒绝过度复杂的查询。 |
| `max_body_size` | `1_048_576` (1MB) | Limits request body size. 限制请求体大小。 |
| `max_connections` | `10000` | Connection limit to prevent FD exhaustion. 连接数上限，防止文件描述符耗尽。 |
| `max_batch_size` | `10` | Limits batch query array length. 限制批量查询数组长度。 |
| `max_alias_count` | `100` | Prevents alias abuse. 防止别名滥用。 |
| `read_timeout_ms` | `30000` (30s) | Drops slow clients. 断开慢速客户端。 |

### 2. Security 安全

**Persisted Queries (Recommended) 持久化查询（推荐）**
```zig
var cache = zg.QueryCache.init(allocator);
defer cache.deinit();
try cache.store("{ hello }");

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .query_cache = &cache,
    .enforce_query_whitelist = true,
});
```

**Rate Limiting 速率限制**
```zig
var rate_limiter = zg.RateLimiter.init(allocator, 1000, 100);
defer rate_limiter.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .rate_limiter = &rate_limiter,
});
```

**Field-Level Authorization 字段级授权**
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

### 3. Observability 可观测性

**Metrics 指标**
```zig
var metrics = zg.MetricsCollector.init(allocator);
defer metrics.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .metrics = &metrics,
});

// Access via /graphql/metrics
// 通过 /graphql/metrics 访问
```

**Distributed Tracing 分布式追踪**
```zig
var tracer = zg.Tracer.init(allocator, io);
defer tracer.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .tracer = &tracer,
});
```

**Audit Logging 审计日志**
```zig
var audit = try zg.AuditLog.init(allocator, io, "/var/log/graphql.jsonl");
defer audit.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .audit_log = &audit,
});
```

### 4. Reverse Proxy 反向代理

For TLS termination and load balancing, place `zgraphql` behind a reverse proxy:

为实现 TLS 终止和负载均衡，将 `zgraphql` 置于反向代理之后：

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

使用 `.bind_unix_path` 通过 Unix 域套接字与代理通信：

```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .bind_unix_path = "/run/zgraphql.sock",
});
```

### 5. Graceful Shutdown 优雅关闭

The server handles `SIGINT` and `SIGTERM` automatically. Active requests are drained before exit.

服务器自动处理 `SIGINT` 和 `SIGTERM`。退出前会等待活跃请求完成。

```bash
# Send SIGTERM for graceful shutdown
kill -TERM $(pidof my-zgraphql-app)
```

### 6. Multi-Tenant Considerations 多租户考量

zgraphql does not provide built-in tenant isolation. For multi-tenant deployments:

zgraphql 不提供内置的租户隔离。多租户部署方案：

- **Option A**: Run one `zgraphql` instance per tenant, routed by a gateway.
- **Option A**: 为每个租户运行独立的 `zgraphql` 实例，通过网关路由。
- **Option B**: Use a single instance with resolver-level tenant filtering via `ExecutionContext.user_data`.
- **Option B**: 单一实例，通过 `ExecutionContext.user_data` 在 resolver 级别进行租户过滤。
- **Option C**: Shard by schema; load different `Schema` objects per request using a routing layer.
- **Option C**: 按 schema 分片；通过路由层为每个请求加载不同的 `Schema` 对象。

### 7. Horizontal Scaling 水平扩展

For high-traffic scenarios, run multiple `zgraphql` processes behind a load balancer:

高流量场景下，在负载均衡器后运行多个 `zgraphql` 进程：

- Use **Redis** or **Memcached** for shared `ResponseCache` (custom implementation required).
- Use **Redis** 或 **Memcached** 作为共享 `ResponseCache`（需自定义实现）。
- Store `QueryCache` (APQ whitelist) in a shared KV store.
- 将 `QueryCache`（APQ 白名单）存储在共享 KV 存储中。
- Stateless design makes scaling straightforward.
- 无状态设计使扩展变得简单直接。
