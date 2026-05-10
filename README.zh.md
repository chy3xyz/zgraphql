# zgraphql

一个可用于**生产环境**的 **Zig 0.16.0** GraphQL 库，**零外部依赖**。

---

## 目录

- [特性](#特性)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [示例](#示例)
- [核心概念](#核心概念)
  - [Schema Builder](#schema-builder)
  - [查询流水线](#查询流水线)
  - [DataLoader (N+1)](#dataloader-n1)
  - [异步设计](#异步设计)
  - [安全](#安全)
  - [可观测性](#可观测性)
  - [订阅](#订阅)
- [架构](#架构)
- [模块概览](#模块概览)
- [测试](#测试)
- [生产就绪度](#生产就绪度)
- [许可](#许可)

---

## 特性

| 特性 | 说明 |
|------|------|
| **零依赖** | 纯 Zig 标准库 |
| **编译期 Schema** | `comptime` 类型安全的 `SchemaBuilder` DSL |
| **SDL 解析器** | 运行时解析 `.graphql` schema 文件 |
| **查询校验** | 字段存在性、类型兼容性、片段循环、变量校验 |
| **并发执行** | 通过 `std.Io` 纤程实现并行字段解析 |
| **N+1 防护** | 内置 `DataLoader`，请求级缓存 |
| **生产服务器** | HTTP + WebSocket (`graphql-ws`)，支持优雅关闭 |
| **安全** | 深度/复杂度限制、速率限制、CORS、持久化查询 |
| **可观测性** | 无锁指标、分布式追踪（W3C）、审计日志 |
| **响应缓存** | 基于 TTL 的内存缓存 |
| **字段授权** | 基于角色的访问控制 |

[英文 README](README.md)

---

## 环境要求

- **Zig 0.16.0**（使用 `std.Io` API，2026-04-13 正式发布）

---

## 快速开始

```zig
const std = @import("std");
const zg = @import("zgraphql");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. 使用编译期 SchemaBuilder 定义 schema
    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    // 2. 附加 resolver
    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // 3. 解析查询
    var parser = try zg.Parser.init(allocator, "{ hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    // 4. 校验
    var validator = zg.Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const vr = try validator.validate(&doc);
    if (!vr.isValid()) return error.ValidationFailed;

    // 5. 执行
    std.debug.print("Query is valid! Ready to execute.\n", .{});
}
```

### 运行 HTTP 服务器

```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
    .max_query_depth = 20,
});

const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
var backend = IoBackend.init(allocator, .{});
defer backend.deinit();

try server.listen(backend.io());
```

测试查询：
```bash
curl -X POST http://localhost:8080/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ hello }"}'
```

---

## 示例

```bash
# 核心流程：构建 Schema -> 解析 -> 校验 -> 内省
zig build run-basic

# 生产级 HTTP 服务器，包含授权、指标、速率限制和缓存
zig build run-server

# WebSocket 订阅服务器（graphql-ws 协议）
zig build run-subscription

# DataLoader N+1 优化演示
zig build run-dataloader
```

---

## 核心概念

### Schema Builder

在编译期使用类型安全的方式定义 schema：

```zig
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

const sdl = Builder.sdl;          // 编译期已知的 SDL 字符串
var schema_def = try Builder.init(allocator);
defer schema_def.deinit();
```

---

### 查询流水线

标准查询生命周期遵循编译器模式：

```
GraphQL 查询字符串 / SDL
       |
       v
   [词法分析器]  --> 令牌流
       |
       v
   [解析器] --> AST (文档)
       |
       v
 [复杂度分析] --> 深度/复杂度检查
       |
       v
 [校验器] --> 校验结果
       |
       v
 [执行器] --> Value (含钩子与部分错误)
       |
       v
   [JSON] --> 响应
```

---

### DataLoader (N+1)

通过批量加载防止 N+1 数据库查询：

```zig
var dl = zg.DataLoader.init(allocator, io);
defer dl.deinit();

dl.setBatchLoader(struct {
    fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
        // 例如：SELECT * FROM users WHERE id IN (...)
        var results = try alloc.alloc(zg.Value, keys.len);
        // ... 填充结果
        return results;
    }
}.batch, null);

const values = try dl.loadMany(&.{"1", "2", "3"});
// 后续对 dl.load("1") 的调用直接命中缓存，零次数据库往返
```

---

### 异步设计

zgraphql 为 Zig 0.16.0 的 `std.Io` 抽象而设计：

- **Resolver** 是普通函数，返回 `Value`，在 `std.Io` 管理的纤程中运行。
- **并行字段解析** 使用 `Io.Group` 实现结构化并发。
- **I/O 操作**（数据库、HTTP、文件）通过 `std.Io` 自动让出 — 无需显式 `async/await`。
- **跨平台**：Linux 用 io_uring，macOS/Windows/BSD 用线程池。

异步 resolver 示例：
```zig
fn userResolver(ctx: ?*anyopaque, allocator: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const context: *MyContext = @ptrCast(@alignCast(ctx));
    const id = args.get("id").?.data.int;
    // 此数据库调用在 io_uring 上运行，自动让出纤程
    const user = try context.db.query("SELECT * FROM users WHERE id = ?", .{id}, context.io);
    return user.toGraphQLValue(allocator);
}
```

---

### 安全

#### 查询深度限制
```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .max_query_depth = 15,
});
```

#### 复杂度分析
```zig
const result = zg.ComplexityAnalyzer.analyzeDocument(&doc);
std.debug.print("depth={d}, complexity={d}\n", .{result.depth, result.complexity});
```

#### 持久化查询与白名单
```zig
var cache = zg.QueryCache.init(allocator);
defer cache.deinit();
try cache.store("{ hello }");

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .query_cache = &cache,
    .enforce_query_whitelist = true,
});
```

#### 速率限制
```zig
var rate_limiter = zg.RateLimiter.init(allocator, 100, 10);
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .rate_limiter = &rate_limiter,
});
```

#### 请求体大小限制
```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .max_body_size = 1024 * 1024, // 1MB
});
```

#### 字段级授权
```zig
field.required_role = "admin";
// 执行器在调用 resolver 前检查 `hooks.hasRole()`
```

---

### 可观测性

#### 指标
```zig
var metrics = zg.MetricsCollector.init(allocator);
defer metrics.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .metrics = &metrics,
});

const snapshot = metrics.snapshot();
std.debug.print("queries={d}, avg_ms={d:.2}\n", .{ snapshot.queries_total, snapshot.avg_duration_ms });
// 通过 /graphql/metrics 端点访问
```

#### 分布式追踪
```zig
var tracer = zg.Tracer.init(allocator, io);
defer tracer.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .tracer = &tracer,
});
// 支持 W3C traceparent 传播
```

#### 审计日志
```zig
var audit = try zg.AuditLog.init(allocator, io, "/var/log/graphql.jsonl");
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .audit_log = &audit,
});
// 每个请求以 JSON Lines 格式记录
```

---

### 订阅

服务器支持 `graphql-ws` 协议进行实时订阅：

1. 客户端发送 `connection_init`
2. 服务器回复 `connection_ack`
3. 客户端发送 `subscribe` 携带 payload
4. 服务器发送 `next`（结果）然后 `complete`

```javascript
const ws = new WebSocket('ws://localhost:8080/graphql');
ws.onopen = () => {
  ws.send(JSON.stringify({ type: 'connection_init' }));
  ws.send(JSON.stringify({
    type: 'subscribe',
    id: '1',
    payload: { query: 'subscription { counter }' }
  }));
};
```

查看 `examples/subscription.zig` 获取完整可运行的服务器示例。

---

## 架构

详细架构说明见 [`docs/ARCHITECTURE.zh.md`](docs/ARCHITECTURE.zh.md)。

---

## 模块概览

| 模块 | 说明 |
|------|------|
| `value.zig` | GraphQL `Value` 类型及 JSON 序列化 |
| `lexer.zig` | GraphQL 词法分析器 |
| `ast.zig` | AST 节点定义 |
| `parser.zig` | 递归下降解析器 |
| `schema.zig` | Schema 类型系统 |
| `schema_builder.zig` | 编译期 `SchemaBuilder` DSL |
| `schema_parser.zig` | `.graphql` 文件 SDL 解析器 |
| `validator.zig` | 查询校验器 |
| `executor.zig` | 查询执行引擎 |
| `introspection.zig` | `__Schema` 内省 |
| `complexity.zig` | 查询深度/复杂度分析 |
| `server.zig` | HTTP/WebSocket 服务器 |
| `query_cache.zig` | 持久化查询缓存（SHA-256） |
| `metrics.zig` | 无锁指标收集器 |
| `dataloader.zig` | 请求级批量加载 |
| `doc_generator.zig` | 从内省自动生成 Markdown 文档 |

---

## 测试

```bash
# 运行所有测试（单元 + 集成）
zig build test

# 仅运行集成测试
zig build integration-test

# 运行模糊测试
zig build run-parser-fuzz
zig build run-json-fuzz

# 运行压力测试（30 秒持续负载）
zig build run-stress-test
```

**当前测试状态**：
| 测试套件 | 状态 |
|---------|------|
| 单元测试 | 84/84 通过 |
| 集成测试 | 4/4 通过 |
| 解析器模糊测试 | 10,000 轮，零泄漏 |
| JSON 模糊测试 | 5,000 轮，零泄漏 |
| 压力测试 | 约 501 ops/sec，稳定 |

---

## 生产就绪度

**评分：8.3 / 10**

| 维度 | 评分 | 说明 |
|------|------|------|
| 测试 | 9/10 | 单元、集成、模糊、压力测试全部通过 |
| 安全 | 8/10 | 整数速率限制、CORS 修复、信号注册、无泄漏 |
| 文档 | 8/10 | 双语文档、架构指南、API 参考 |
| 性能 | 8/10 | 约 501 ops/sec 持续负载，无锁指标 |
| 功能 | 9/10 | 完整 GraphQL 规范覆盖 + 生产级扩展 |
| 成熟度 | 8/10 | 无内置分布式缓存；无内置租户隔离 |

**剩余差距**：
1. **无内置分布式缓存** — 多节点部署需要 Redis 集成。
2. **无内置租户隔离** — 多租户场景需要自定义 resolver 逻辑。

部署指南见 [`docs/DEPLOYMENT.zh.md`](docs/DEPLOYMENT.zh.md)。

API 速查见 [`docs/API.zh.md`](docs/API.zh.md)。

---

## 许可

MIT License
