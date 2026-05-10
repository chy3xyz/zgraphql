# 部署指南

## 快速部署

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

## 生产检查清单

### 1. 资源限制

| 选项 | 推荐值 | 说明 |
|------|--------|------|
| `max_query_depth` | `15` | 防止深层嵌套的 DoS 查询 |
| `max_query_complexity` | `1000` | 拒绝过度复杂的查询 |
| `max_body_size` | `1_048_576` (1MB) | 限制请求体大小 |
| `max_connections` | `10000` | 连接数上限，防止文件描述符耗尽 |
| `max_batch_size` | `10` | 限制批量查询数组长度 |
| `max_alias_count` | `100` | 防止别名滥用 |
| `read_timeout_ms` | `30000` (30s) | 断开慢速客户端 |

### 2. 安全

**持久化查询（推荐）**
```zig
var cache = zg.QueryCache.init(allocator);
defer cache.deinit();
try cache.store("{ hello }");

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .query_cache = &cache,
    .enforce_query_whitelist = true,
});
```

**速率限制**
```zig
var rate_limiter = zg.RateLimiter.init(allocator, 1000, 100);
defer rate_limiter.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .rate_limiter = &rate_limiter,
});
```

**字段级授权**
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

在 schema 字段上设置 `.required_role` 来强制执行：
```zig
field.required_role = "admin";
```

### 3. 可观测性

**指标**
```zig
var metrics = zg.MetricsCollector.init(allocator);
defer metrics.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .metrics = &metrics,
});

// 通过 /graphql/metrics 访问
```

**分布式追踪**
```zig
var tracer = zg.Tracer.init(allocator, io);
defer tracer.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .tracer = &tracer,
});
```

**审计日志**
```zig
var audit = try zg.AuditLog.init(allocator, io, "/var/log/graphql.jsonl");
defer audit.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .audit_log = &audit,
});
```

### 4. 反向代理

为实现 TLS 终止和负载均衡，将 `zgraphql` 置于反向代理之后：

```nginx
# nginx 示例
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

使用 `.bind_unix_path` 通过 Unix 域套接字与代理通信：

```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .bind_unix_path = "/run/zgraphql.sock",
});
```

### 5. 优雅关闭

服务器自动处理 `SIGINT` 和 `SIGTERM`。退出前会等待活跃请求完成。

```bash
# 发送 SIGTERM 进行优雅关闭
kill -TERM $(pidof my-zgraphql-app)
```

### 6. 多租户考量

zgraphql 不提供内置的租户隔离。多租户部署方案：

- **方案 A**：为每个租户运行独立的 `zgraphql` 实例，通过网关路由。
- **方案 B**：单一实例，通过 `ExecutionContext.user_data` 在 resolver 级别进行租户过滤。
- **方案 C**：按 schema 分片；通过路由层为每个请求加载不同的 `Schema` 对象。

### 7. 分布式缓存（多节点）

多节点部署时，使用 `DistributedCache` 配合 HTTP 缓存后端：

```zig
var http_backend = try zg.HttpCacheBackend.init(allocator, "http://cache-proxy:8080");
defer http_backend.deinit();

var dc = zg.DistributedCache.init(
    allocator,
    http_backend.cacheBackend(),
    "zgraphql:",
    &response_cache, // L1 本地缓存
);
defer dc.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .response_cache = &response_cache,
    .distributed_cache = &dc,
});
```

缓存代理可以是 Varnish、带缓存的 Nginx，或自定义的轻量级缓存服务。期望的 REST API：
- `GET /{key}` -> 200 返回 body 或 404
- `PUT /{key}?ttl={ms}` -> 存储 body 并设置 TTL
- `DELETE /{key}` -> 删除条目

如需使用 Redis，可通过 RESP 客户端实现 `CacheBackend` 接口。

### 8. 租户隔离（多租户）

注册具有独立限制的租户：

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

默认通过 `X-Tenant-ID` 请求头解析租户。每个请求受租户配置的限制约束。如果没有匹配的租户且未设置默认租户，则使用全局服务器选项。

### 9. Playground

开发阶段启用内置的 GraphQL IDE：

```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .enable_playground = true,
});
```

访问 `http://localhost:8080/graphql/playground`。

- **离线模式**（默认）：零依赖的极简 Playground，支持查询编辑、变量输入、响应格式化和内省。
- **CDN 模式**：将 `server.zig` 中的 HTML 替换为 `graphiql_html` 即可通过 CDN 提供 GraphiQL。

**生产环境建议关闭**，以减少攻击面：
```zig
.enable_playground = false, // 默认值
```

### 10. 水平扩展

高流量场景下，在负载均衡器后运行多个 `zgraphql` 进程：

- 使用 `DistributedCache` 配合 HTTP 缓存后端，在节点间共享查询结果。
- 将 `QueryCache`（APQ 白名单）存储在共享 KV 存储中。
- 无状态设计使扩展变得简单直接。
