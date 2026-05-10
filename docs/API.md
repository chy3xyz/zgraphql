# API Quick Reference

## Core Types

### Value
```zig
pub const Value = struct {
    allocator: std.mem.Allocator,
    data: Data,

    pub const Data = union(enum) {
        null: void,
        int: i64,
        float: f64,
        string: []const u8,
        boolean: bool,
        enum_value: []const u8,
        list: ArrayList(Value),
        object: std.StringHashMap(Value),
    };
};
```

**Constructors**
```zig
Value.fromNull(allocator)
Value.fromInt(allocator, v: i64)
Value.fromFloat(allocator, v: f64)
Value.fromString(allocator, v: []const u8)    // takes ownership
Value.fromBool(allocator, v: bool)
Value.fromEnum(allocator, v: []const u8)      // takes ownership
Value.initList(allocator)
Value.initObject(allocator)
```

**Lifecycle**
```zig
value.deinit()      // Deep free
value.clone()       // Deep copy
value.toJson()      // Serialize to JSON string
```

---

### Parser
```zig
var parser = try zg.Parser.init(allocator, source);
defer parser.deinit();
var doc = try parser.parseDocument();
defer doc.deinit();
```

---

### Validator
```zig
var validator = zg.Validator.init(allocator, &schema_def);
defer validator.deinit();
const result = try validator.validate(&doc);
if (!result.isValid()) { ... }
```

---

### Executor
```zig
var executor = zg.Executor.init(allocator, &schema_def, io);
defer executor.deinit();
var result = try executor.execute(&doc);
defer result.deinit();
```

**Execution Hooks**
```zig
pub const ExecutionHooks = struct {
    before_field_execute: ?*const fn (ctx: ?*anyopaque, field_name: []const u8) bool,
    after_field_execute:  ?*const fn (ctx: ?*anyopaque, field_name: []const u8, had_error: bool, duration_ns: u64) void,
    on_error:             ?*const fn (ctx: ?*anyopaque, message: []const u8) void,
    hasRole:              ?*const fn (ctx: ?*anyopaque, role: []const u8) bool,
};
```

---

### SchemaBuilder (comptime)
```zig
const Builder = comptime zg.SchemaBuilder(.{
    .Query = .{
        .hello = .{ .type = "String!" },
    },
});

const sdl = Builder.sdl;              // comptime string
var schema_def = try Builder.init(allocator);
defer schema_def.deinit();
```

---

### GraphQLServer
```zig
var server = zg.GraphQLServer.init(allocator, &schema_def, .{
    .bind_address = std.Io.net.IpAddress.parseIp4("0.0.0.0", 8080) catch unreachable,
    .max_query_depth = 20,
    .max_query_complexity = 1000,
    .max_body_size = 1024 * 1024,
    .query_cache = &cache,
    .enforce_query_whitelist = false,
    .metrics = &metrics,
    .hooks = hooks,
    .rate_limiter = &rate_limiter,
    .response_cache = &response_cache,
    .user_data = &ctx,
    .audit_log = &audit,
    .tracer = &tracer,
});
try server.listen(io);
```

---

### DataLoader
```zig
var dl = zg.DataLoader.init(allocator, io);
defer dl.deinit();

dl.setBatchLoader(struct {
    fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value { ... }
}.batch, null);

// Load from cache or batch
const v = dl.load("key1");
const vs = try dl.loadMany(&.{"1", "2", "3"});
```

---

### MetricsCollector
```zig
var metrics = zg.MetricsCollector.init(allocator);
defer metrics.deinit();

metrics.recordQuery(duration_ns, complexity, had_error);
metrics.recordResolver(field_name, duration_ns, had_error);

const s = metrics.snapshot();
// s.queries_total, s.avg_duration_ms, s.max_duration_ms ...

const json = try metrics.toJson(allocator);
defer allocator.free(json);
```

---

### RateLimiter
```zig
var limiter = zg.RateLimiter.init(allocator, capacity, refill_rate);
// capacity: max burst tokens
// refill_rate: tokens per second

const allowed = limiter.allow("client_id", now_ms);
```

---

### ResponseCache
```zig
var cache = zg.ResponseCache.init(allocator, ttl_ms);

cache.put(query, json_response, now_ms) catch {};
const cached = cache.get(query, now_ms);
cache.prune(now_ms);
```

---

### Tracer
```zig
var tracer = zg.Tracer.init(allocator, io);
defer tracer.deinit();

var root = try tracer.startRootSpan("graphql.execute", trace_id);
tracer.endSpan(root);

const json = try tracer.exportJson(allocator);
```

---

### DistributedCache
```zig
var backend = zg.SimpleMemoryBackend.init(allocator);
defer backend.deinit();

var dc = zg.DistributedCache.init(allocator, backend.cacheBackend(), "prefix:", &l1_cache);
defer dc.deinit();

const cached = try dc.get("{ hello }", now_ms);
const json = try dc.get("{ hello }", now_ms);
try dc.set("{ hello }", json_str, ttl_ms, now_ms);
try dc.setWithDefaultTtl("{ hello }", json_str, now_ms);
try dc.delete("{ hello }");
```

**HttpCacheBackend**
```zig
var http = try zg.HttpCacheBackend.init(allocator, "http://cache:8080");
defer http.deinit();
var dc = zg.DistributedCache.init(allocator, http.cacheBackend(), "prefix:", &l1);
```

**Custom Backend**
```zig
const my_backend = zg.CacheBackend{
    .get = myGetFn,
    .set = mySetFn,
    .delete = myDeleteFn,
    .ctx = &my_state,
};
```

---

### TenantManager
```zig
var tm = zg.TenantManager.init(allocator);
defer tm.deinit();

try tm.register(.{
    .id = "tenant-a",
    .max_query_depth = 10,
    .max_query_complexity = 500,
    .max_body_size = 512 * 1024,
    .rate_limiter = &limiter,
    .enforce_query_whitelist = true,
    .roles = &.{"user"},
});

try tm.setDefault(.{ .id = "default", .max_query_depth = 20 });

const tenant = tm.resolve(request_headers);
const by_id = tm.resolveById("tenant-a");
```

---

## Error Types

```zig
pub const ExecutionError = error{
    ResolverError,
    InvalidField,
    InvalidArgument,
    NullValueForNonNull,
    Unauthorized,
    PermissionDenied,
    NotFound,
    Timeout,
    InvalidInput,
    ExternalServiceError,
    RateLimited,
} || std.mem.Allocator.Error;
```

## Constants

| Name | Default | Description |
|------|---------|-------------|
| `max_server_instances` | `16` | Max concurrent server instances for signal handling. |
