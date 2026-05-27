# Architecture

## Overview

`zgraphql` follows a classic compiler pipeline architecture, adapted for GraphQL query execution:

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

## Design Principles

### Zero External Dependencies
All functionality is implemented using only the Zig standard library. This eliminates supply-chain attack vectors and ensures the library remains maintainable as Zig evolves.

### Memory Safety
- Every heap-allocated value has a corresponding `deinit()`.
- `errdefer` is used extensively to prevent leaks on error paths.
- Unit tests run under `std.testing.allocator` which detects leaks automatically.

### Concurrency Model
Built for Zig 0.17.0's `std.Io` abstraction:
- **Linux**: io_uring backend for true async I/O.
- **macOS/Windows/BSD**: Threaded backend using a work-stealing thread pool.
- Resolvers are plain functions that run inside fibers managed by `std.Io`. No explicit `async/await` syntax is required.

## Module Responsibilities

| Module | Responsibility |
|--------|----------------|
| `lexer.zig` | Converts raw GraphQL text into a stream of `Token` structs. Handles strings, numbers, names, punctuators, and comments. |
| `parser.zig` | Recursive-descent parser that consumes tokens and builds an `AST` (`Document`). |
| `ast.zig` | AST node definitions (`Document`, `OperationDefinition`, `Field`, `SelectionSet`, etc.). |
| `schema.zig` | Runtime schema type system. Defines `Schema`, `Type`, `Field`, `TypeRef`, and builtin directives. |
| `schema_builder.zig` | `comptime` DSL that generates GraphQL SDL from Zig struct literals. |
| `schema_parser.zig` | Parses `.graphql` schema definition language files into runtime `Schema` objects. |
| `validator.zig` | Validates a parsed `Document` against a `Schema`. Checks field existence, type compatibility, fragment cycles, and variable definitions. |
| `executor.zig` | Executes a validated query against a schema. Supports concurrent field resolution, partial errors, and execution hooks. |
| `introspection.zig` | Builds the `__Schema` introspection response dynamically from a runtime schema. |
| `server.zig` | HTTP server with GraphQL endpoint, WebSocket upgrade (`graphql-ws`), CORS, health checks, and graceful shutdown. |
| `complexity.zig` | Analyzes query depth and complexity before execution to prevent DoS. |
| `query_cache.zig` | SHA-256 based query cache for persisted queries (APQ) and whitelisting. |
| `metrics.zig` | Lock-free metrics collection for query counts, durations, error rates, and per-resolver timing. |
| `dataloader.zig` | Request-level batch loading and caching to solve the N+1 problem. |
| `rate_limiter.zig` | Token-bucket rate limiter using integer arithmetic for production stability. |
| `response_cache.zig` | TTL-based in-memory response cache for cacheable queries. |
| `distributed_cache.zig` | Two-tier cache (L1 local + L2 remote) with pluggable backends (HTTP, in-memory, custom). |
| `tenant.zig` | Multi-tenant manager with per-tenant schema overrides, limits, and query whitelists. |
| `audit_log.zig` | Structured JSON Lines audit logging of every GraphQL request. |
| `tracing.zig` | W3C traceparent compatible distributed tracing with OpenTelemetry-style span export. |
| `doc_generator.zig` | Generates Markdown API documentation from introspection data. |
