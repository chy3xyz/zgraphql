# zgraphql

A **production-ready** GraphQL library for **Zig 0.16.0**, built with zero external dependencies.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Examples](#examples)
- [Core Concepts](#core-concepts)
  - [Schema Builder](#schema-builder)
  - [Query Pipeline](#query-pipeline)
  - [DataLoader (N+1)](#dataloader-n1)
  - [Async Design](#async-design)
  - [Security](#security)
  - [Observability](#observability)
  - [Distributed Cache](#distributed-cache)
- [Tenant Isolation](#tenant-isolation)
- [Subscriptions](#subscriptions)
- [Architecture](#architecture)
- [Module Overview](#module-overview)
- [Testing](#testing)
- [Production Readiness](#production-readiness)
- [License](#license)

---

## Features

| Feature | Description |
|---------|-------------|
| **Zero Dependencies** | Pure Zig standard library only |
| **Compile-time Schema** | Type-safe `SchemaBuilder` DSL at `comptime` |
| **SDL Parser** | Parse `.graphql` schema files at runtime |
| **Query Validation** | Field existence, type compatibility, fragment cycles, variables |
| **Concurrent Execution** | Parallel field resolution via `std.Io` fibers |
| **N+1 Prevention** | Built-in `DataLoader` with request-level caching |
| **Production Server** | HTTP + WebSocket (`graphql-ws`) with graceful shutdown |
| **Security** | Depth/complexity limits, rate limiting, CORS, persisted queries |
| **Observability** | Lock-free metrics, distributed tracing (W3C), audit logging |
| **Response Cache** | TTL-based in-memory cache for cacheable queries |
| **Distributed Cache** | Built-in two-tier cache (L1 local + L2 remote) with pluggable backends (HTTP, custom) |
| **Tenant Isolation** | Per-tenant schema overrides, rate limits, complexity limits, and query whitelists |
| **Field Auth** | Role-based access control via `ExecutionHooks` |

[Chinese README](README.zh.md)

---

## Requirements

- **Zig 0.16.0** (uses `std.Io` API, released 2026-04-13)

---

## Quick Start

```zig
const std = @import("std");
const zg = @import("zgraphql");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Define schema with comptime SchemaBuilder
    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    // 2. Attach resolver
    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // 3. Parse query
    var parser = try zg.Parser.init(allocator, "{ hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    // 4. Validate
    var validator = zg.Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const vr = try validator.validate(&doc);
    if (!vr.isValid()) return error.ValidationFailed;

    // 5. Execute
    std.debug.print("Query is valid! Ready to execute.\n", .{});
}
```

### Run HTTP Server

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

Query it:
```bash
curl -X POST http://localhost:8080/graphql \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ hello }"}'
```

---

## Examples

```bash
# Core pipeline: SchemaBuilder -> Parser -> Validator -> Introspection
zig build run-basic

# Production HTTP server with auth, metrics, rate limiting, and caching
zig build run-server

# WebSocket subscription server (graphql-ws protocol)
zig build run-subscription

# DataLoader N+1 optimization demonstration
zig build run-dataloader
```

---

## Core Concepts

### Schema Builder

Define schemas at compile time with type safety:

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

const sdl = Builder.sdl;          // comptime-known SDL string
var schema_def = try Builder.init(allocator);
defer schema_def.deinit();
```

---

### Query Pipeline

The standard query lifecycle follows the compiler pattern:

```
GraphQL Query String / SDL
       |
       v
   [Lexer]  --> Tokens
       |
       v
   [Parser] --> AST (Document)
       |
       v
 [Complexity] --> Depth/Complexity Check
       |
       v
 [Validator] --> ValidationResult
       |
       v
 [Executor] --> Value (with hooks & partial errors)
       |
       v
   [JSON] --> Response
```

---

### DataLoader (N+1)

Prevent N+1 database queries by batching loads:

```zig
var dl = zg.DataLoader.init(allocator, io);
defer dl.deinit();

dl.setBatchLoader(struct {
    fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
        // e.g., SELECT * FROM users WHERE id IN (...)
        var results = try alloc.alloc(zg.Value, keys.len);
        // ... populate results
        return results;
    }
}.batch, null);

const values = try dl.loadMany(&.{"1", "2", "3"});
// Subsequent calls to dl.load("1") hit the cache, zero DB round-trips
```

---

### Async Design

zgraphql is architected for Zig 0.16.0's `std.Io` abstraction:

- **Resolvers** are plain functions that return `Value`. They run inside fibers managed by `std.Io`.
- **Concurrent field resolution** uses `Io.Group` for structured concurrency.
- **I/O operations** (database, HTTP, file) automatically yield via `std.Io` — no explicit `async/await` syntax.
- **Cross-platform**: `io_uring` on Linux, thread pool on macOS/Windows/BSD.

Example async resolver:
```zig
fn userResolver(ctx: ?*anyopaque, allocator: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const context: *MyContext = @ptrCast(@alignCast(ctx));
    const id = args.get("id").?.data.int;
    // This database call runs on io_uring and yields the fiber automatically
    const user = try context.db.query("SELECT * FROM users WHERE id = ?", .{id}, context.io);
    return user.toGraphQLValue(allocator);
}
```

---

### Security

#### Query Depth Limiting
```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .max_query_depth = 15,
});
```

#### Complexity Analysis
```zig
const result = zg.ComplexityAnalyzer.analyzeDocument(&doc);
std.debug.print("depth={d}, complexity={d}\n", .{result.depth, result.complexity});
```

#### Persisted Queries & Whitelist
```zig
var cache = zg.QueryCache.init(allocator);
defer cache.deinit();
try cache.store("{ hello }");

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .query_cache = &cache,
    .enforce_query_whitelist = true,
});
```

#### Rate Limiting
```zig
var rate_limiter = zg.RateLimiter.init(allocator, 100, 10);
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .rate_limiter = &rate_limiter,
});
```

#### Body Size Limits
```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .max_body_size = 1024 * 1024, // 1MB
});
```

#### Field-Level Authorization
```zig
field.required_role = "admin";
// The executor checks `hooks.hasRole()` before invoking the resolver
```

---

### Observability

#### Metrics
```zig
var metrics = zg.MetricsCollector.init(allocator);
defer metrics.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .metrics = &metrics,
});

const snapshot = metrics.snapshot();
std.debug.print("queries={d}, avg_ms={d:.2}\n", .{ snapshot.queries_total, snapshot.avg_duration_ms });
// Access via /graphql/metrics endpoint
```

#### Distributed Tracing
```zig
var tracer = zg.Tracer.init(allocator, io);
defer tracer.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .tracer = &tracer,
});
// Supports W3C traceparent propagation
```

#### Audit Logging
```zig
var audit = try zg.AuditLog.init(allocator, io, "/var/log/graphql.jsonl");
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .audit_log = &audit,
});
// Every request is logged as a JSON Lines entry
```

---

### Distributed Cache

zgraphql includes a built-in `DistributedCache` for cross-process/node caching:

```zig
var backend = zg.SimpleMemoryBackend.init(allocator);
defer backend.deinit();

var dc = zg.DistributedCache.init(
    allocator,
    backend.cacheBackend(),
    "service:graphql:",  // key prefix
    &response_cache,     // optional L1 local cache
);
defer dc.deinit();

var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .response_cache = &response_cache,
    .distributed_cache = &dc,
});
```

For HTTP-based backends (e.g. Varnish, custom cache proxy):

```zig
var http_backend = try zg.HttpCacheBackend.init(allocator, "http://cache:8080");
defer http_backend.deinit();

var dc = zg.DistributedCache.init(
    allocator,
    http_backend.cacheBackend(),
    "service:graphql:",
    &response_cache,
);
```

**Custom backend**: implement the `CacheBackend` interface with your own Redis/Memcached client:

```zig
const my_backend = zg.CacheBackend{
    .get = myGetFn,
    .set = mySetFn,
    .delete = myDeleteFn,
    .ctx = &my_state,
};
```

---

### Tenant Isolation

Multi-tenant deployments are supported via `TenantManager`:

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
    .tenant_header = "X-Tenant-ID",
});
```

Tenants are resolved from the request header (default: `X-Tenant-ID`). Each tenant can have its own:
- Schema override
- Query depth / complexity limits
- Body size limit
- Rate limiter
- Query whitelist
- Roles

---

### Subscriptions

The server supports the `graphql-ws` protocol for real-time subscriptions:

1. Client sends `connection_init`
2. Server responds `connection_ack`
3. Client sends `subscribe` with payload
4. Server sends `next` (result) then `complete`

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

See `examples/subscription.zig` for a complete working server.

---

## Architecture

For a detailed architecture overview, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Module Overview

| Module | Description |
|--------|-------------|
| `value.zig` | GraphQL `Value` type with JSON serialization |
| `lexer.zig` | GraphQL tokenization |
| `ast.zig` | AST node definitions |
| `parser.zig` | Recursive descent parser |
| `schema.zig` | Schema type system |
| `schema_builder.zig` | Compile-time `SchemaBuilder` DSL |
| `schema_parser.zig` | SDL parser for `.graphql` files |
| `validator.zig` | Query validation |
| `executor.zig` | Query execution engine |
| `introspection.zig` | `__Schema` introspection |
| `complexity.zig` | Query depth/complexity analysis |
| `server.zig` | HTTP/WebSocket server |
| `query_cache.zig` | Persisted query cache (SHA-256) |
| `metrics.zig` | Lock-free metrics collector |
| `dataloader.zig` | Request-level batch loading |
| `doc_generator.zig` | Auto-generated Markdown docs from introspection |

---

## Testing

```bash
# Run all tests (unit + integration)
zig build test

# Run integration tests only
zig build integration-test

# Run fuzz tests
zig build run-parser-fuzz
zig build run-json-fuzz

# Run stress test (30s sustained load)
zig build run-stress-test
```

**Current test status**:
| Suite | Status |
|-------|--------|
| Unit tests | 84/84 passing |
| Integration tests | 4/4 passing |
| Parser fuzz | 10,000 iters, 0 leaks |
| JSON fuzz | 5,000 iters, 0 leaks |
| Stress test | ~501 ops/sec, stable |

---

## Production Readiness

**Score: 9.0 / 10**

| Area | Score | Notes |
|------|-------|-------|
| Testing | 9/10 | Unit, integration, fuzz, stress tests all passing |
| Safety | 9/10 | Integer rate limiting, CORS fixes, signal registry, leak-free |
| Documentation | 9/10 | Bilingual docs, architecture guide, API reference |
| Performance | 8/10 | ~501 ops/sec sustained, lock-free metrics, L1+L2 caching |
| Features | 10/10 | Complete GraphQL spec + distributed cache + tenant isolation |
| Maturity | 9/10 | Built-in distributed cache and tenant isolation |

**Remaining gaps**:
1. **No built-in Redis protocol** — HTTP cache backend is provided; native Redis RESP requires a custom `CacheBackend` implementation.

For deployment guidance, see [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

For API quick reference, see [`docs/API.md`](docs/API.md).

---

## License

MIT License
