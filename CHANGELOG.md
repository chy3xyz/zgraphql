# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Full custom directive support: schema declaration, validation, and execution pipeline
- Query Plan Cache for pre-validated execution plans
- Distributed tracing integration with OpenTelemetry-compatible span propagation
- Auto-generated API documentation from introspection (`DocGenerator`)

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

[Unreleased]: https://github.com/chy3xyz/zgraphql/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/chy3xyz/zgraphql/releases/tag/v0.1.1
[0.1.0]: https://github.com/chy3xyz/zgraphql/releases/tag/v0.1.0
