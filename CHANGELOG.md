# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **`DataLoader.loadBatched` was broken dead code**: it used the removed `std.ArrayList.init` API and the old `Value.clone()`/`Value.deinit()` signatures, and had a malformed double-`!` return type. It now compiles and passes a fast-path test.
- **`DistributedCache.setValue` was broken dead code**: it accessed the removed `value.allocator` field and called `value.toJson()` without an allocator. Now uses `self.allocator`.
- **`ResponseCache.prune` / `QueryPlanCache.prune` / `RateLimiter.prune` were broken dead code**: `std.ArrayList.init` + `try dupe` in a `void` function (would not compile). Now use `std.array_list.Managed` and degrade gracefully on OOM.
- **`HttpCacheBackend` was broken dead code**: it used the pre-0.17 `std.http.Client.open` API (which no longer exists) and constructed `Client` without the required `io` field. Migrated to `client.fetch`; `init` now takes an `io` argument (breaking).
- **`TenantManager.tenantHooks` removed**: this uncalled helper attempted to capture the outer `base` parameter in a nested function (Zig has no closures), so it could never compile. It was never exported or used.
- **`Value.clone` OOM leak**: a successfully cloned child value leaked when the subsequent list append / map insert failed. Each cloned child is now cleaned up on error.
- **Docs**: `docs/API.md` / `docs/API.zh.md` Value lifecycle examples updated to the explicit-allocator signatures; `HttpCacheBackend.init` docs updated with the new `io` argument.

### Added
- **`zig build compile-all`**: a compile-time probe (`src/compile_all.zig`) that takes the address of every public function, forcing its body to be type-checked. This catches dead-code regressions (uncalled pub fns with compile errors) that Zig's lazy compilation would otherwise miss. Wired into `zig build test` and CI.
- Tests exercising the previously-dead code paths: `DataLoader.loadBatched` fast path, `DistributedCache.setValue`, `ResponseCache.prune`.

## [0.6.0] - 2026-08-06

### Changed
- **`Value` no longer stores an allocator** (breaking): `deinit`, `clone`, `toJson`, and `writeJson` now take an explicit allocator argument, matching the Zig convention and enabling cross-allocator cloning (e.g. into an arena). `cloneWith` was folded into `clone(self, allocator)`; the allocator-dependent `format` method was removed.
- **`server.zig` split** into `server.zig` (HTTP core), `server_ws.zig` (WebSocket graphql-ws protocol), `server_apq.zig` (Automatic Persisted Queries), and `server_playground.zig` (playground HTML). `server.zig` dropped from ~2314 to ~1808 lines.

## [0.5.0] - 2026-08-06

### Fixed
- **Multi-tenant response cache isolation**: the response/distributed cache key was only the query string, so different tenants sharing a global cache could read each other's cached responses. The cache key is now tenant-scoped.
- **`DataLoader.load` swallowed errors**: lock and clone failures were silently converted to `null` (indistinguishable from a cache miss). `load` now returns `anyerror!?Value` and propagates errors.
- **OOM leaks across the engine** (found by new `checkAllAllocationFailures` tests):
  - `Parser.parseDocument`/`parseSelectionSet` leaked successfully parsed values when appending to the list failed.
  - `Schema.init` used `catch unreachable` for builtin-directive registration, panicking on OOM; it is now `!Schema` and propagates errors.
  - `registerBuiltinDirectives` lacked `errdefer` cleanup for directive/location/argument allocations.
  - `Executor` result-building used the `put(try dupe(...), value)` anti-pattern, leaking keys/values on OOM.
- **`Schema.init` is now fallible** (`!Schema`): OOM during builtin-directive registration no longer panics.
- **`queryIsQuery` keyword matching**: `queryFoo` no longer matches the `query` keyword; a whole-keyword check is used.

### Changed
- **Broken import cycle**: `server.zig` no longer imports `zgraphql.zig` (which re-exports it); it now imports internal modules directly, keeping embedded users who don't need the HTTP server out of the module graph.
- **Playground HTML split** into `src/server_playground.zig`.
- **`Value.cloneWith(allocator)`** added for cross-allocator cloning (arena/request-scoped reuse); `clone()` now delegates to it.

### Added
- OOM-injection tests for the parser and executor (every allocation failure is exercised).
- Concurrent `QueryCache` get/store test.
- Multi-tenant response-cache isolation test.
- Cross-allocator `Value.cloneWith` test.
- Benchmark JSON output (`BENCHMARK_JSON=...`) and a 100ms/iter catastrophic-regression smoke check.

## [0.4.1] - 2026-08-06

### Fixed
- **WS subscription path missing `user_data`**: the WebSocket subscription executor never called `setUserData`, so subscription resolvers received a null ctx and panicked on dereference (`attempt to use null value`). The subscription path now sets `user_data` like the HTTP query path.

## [0.4.0] - 2026-08-06

### Fixed
- **APQ use-after-free**: `resolvePersistedQuery` returned a `QueryCache` internal pointer that was freed by the caller, dangling the cache entry and double-freeing at shutdown. Cache lookups now return owned copies (matching `ResponseCache` semantics).
- **APQ error-path double free**: `provided_query` was freed before sending the error response; on error propagation the caller's deferred free then freed it again. Error responses are now sent before ownership is released.
- **Response cache leak**: L1 cache hit path duplicated an already-owned copy and leaked the first one.
- **QueryCache thread safety**: `QueryCache` was lock-free and unsafe under concurrent requests; all methods now use an internal spin lock.
- **Mutation/subscription response caching**: mutations (and subscriptions) with no variables were incorrectly cached and replayed; cacheable checks now verify the operation is a query.
- **`TenantManager` header ownership**: `setHeaderName`/`deinit` decided whether to free by comparing content to the default literal, leaking when the same string was heap-allocated; replaced with an explicit ownership flag.
- **`TenantManager.register` OOM cleanup**: `errdefer` freed uninitialized elements of the roles array on partial allocation failure; now tracks the filled count.
- **Cross-request variable leakage in `Executor`**: default variable values injected by `executeNamed` were never cleaned up, leaking into subsequent executions on a reused executor (and a double-free in the cleanup path).
- **Introspection validation no-op**: `__schema`/`__type` sub-selections were never actually validated because the introspection types are not registered in the user schema; added a real validator over the static introspection type system.
- **`DistributedCache` prefix lifetime**: `init` stored the caller's prefix by reference and `deinit` freed it, crashing on string literals; the prefix is now copied and ownership-tracked.
- **Validation error payload OOM leaks**: partially built error objects were not cleaned up on allocation failure.
- **Documentation errors**: README used a non-existent `ServerOptions.tenant_header` field; `DistributedCache` examples passed string literals as prefix; the subscription example bound `resolve` instead of `subscribe`; `docs/DEPLOYMENT.md` contradicted itself about tenant isolation.
- **Example memory leaks**: `examples/dataloader.zig` and `examples/database.zig` leaked loaded values (double clone / missing deinit); `examples/complex.zig` used enum workarounds, an unused subscription, and redundant root-type wiring.
- **CI**: fuzz job swallowed failures with `|| true`; stress test was never run in CI; both are now enforced.
- **Error observability**: execution errors returned a generic "Execution error"; the response now includes the concrete error name, and GraphQL errors include `locations` (line/column).

### Added
- `examples/typesafe.zig`: runnable `TypeSafeSchemaBuilder` example.
- Mutation end-to-end tests (executor side effects, validator rejection without mutation root).
- Introspection validation tests (valid/unknown-field/leaf-with-sub-selection).
- Benchmark warm-up and schema-build-out-of-hot-loop improvements.

## [0.3.1] - 2026-07-23

### Changed
- Updated type reflection for compatibility with latest Zig 0.17 dev (`@typeInfo` struct and function layout changes)

## [0.3.0] - 2026-05-28

### Added
- Full custom directive support: schema declaration, validation, and execution pipeline
- Query Plan Cache for pre-validated execution plans
- Distributed tracing integration with OpenTelemetry-compatible span propagation
- Auto-generated API documentation from introspection (`DocGenerator`)

### Changed
- Migrated to Zig 0.17.0 (`std.Io` API)

## [0.1.1] - 2026-05-10

### Added
- **Complex Example** (`examples/complex.zig`): Comprehensive real-world-style GraphQL API demonstrating the full zgraphql feature set in a single application:
  - Multi-domain schema (e-commerce + social): Users, Posts, Comments, Products, Orders
  - Nested field resolvers with DataLoader batch loading for N+1 prevention
  - Role-based field authorization (`users` query requires admin role)
  - Tenant isolation with per-tenant resource limits
  - Distributed cache (L1 response cache + L2 in-memory backend)
  - Rate limiting, metrics collection, and built-in GraphQL Playground
  - Mutations for creating posts and orders
  - Subscription schema with WebSocket support

## [0.1.0] - 2026-05-09

### Added
- **Core GraphQL engine**: Lexer, Parser, AST, Validator, Executor with partial results
- **Schema type system**: Objects, Scalars, Enums, Interfaces, Unions, Input Objects
- **Compile-time SchemaBuilder**: Type-safe DSL generating GraphQL SDL at comptime
- **SDL Parser**: Parse `.graphql` schema definition files into runtime `Schema`
- **Introspection**: Built-in `__Schema` introspection query support
- **HTTP Server**: Production-ready GraphQL endpoint using `std.Io` with graceful shutdown
- **WebSocket Subscriptions**: `graphql-ws` protocol with concurrent subscription support
- **Security**: Query depth limiting, complexity analysis, body size limits, field-level auth
- **Persisted Queries / APQ**: SHA-256 query cache with automatic persisted queries and HMAC signature verification
- **Rate Limiting**: Token-bucket IP-based rate limiter
- **Response Caching**: TTL cache with configurable expiration
- **Metrics**: `MetricsCollector` with resolver-level timing and `/graphql/metrics` endpoint
- **DataLoader**: Request-level batch loading and caching for N+1 prevention
- **Audit Logging**: JSON Lines audit log with query/variable/error recording
- **Error Handling**: Categorized errors (`ParserError`, `ValidationError`, `ExecutionFailed`, `DepthLimitExceeded`, `ComplexityLimitExceeded`, `Unauthorized`) with path tracking
- **Type-Safe Resolvers**: `TypeSafeSchemaBuilder` with automatic argument coercion and value serialization
- **Performance Benchmarks**: Parse/validate/execute/e2e benchmark suite
- **Health Endpoints**: `/health` and `/ready` probes
- **Graceful Shutdown**: SIGINT/SIGTERM handling with active request draining
- **Zero External Dependencies**: Pure Zig standard library

[0.6.0]: https://github.com/chy3xyz/zgraphql/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/chy3xyz/zgraphql/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/chy3xyz/zgraphql/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/chy3xyz/zgraphql/compare/v0.3.1...v0.4.0
[0.3.0]: https://github.com/chy3xyz/zgraphql/releases/tag/v0.3.0
[0.1.1]: https://github.com/chy3xyz/zgraphql/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/chy3xyz/zgraphql/releases/tag/v0.1.0
