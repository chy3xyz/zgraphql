# 架构

## 概述

`zgraphql` 采用经典的编译器流水线架构，适配于 GraphQL 查询执行：

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

## 设计原则

### 零外部依赖
全部功能仅使用 Zig 标准库实现。这消除了供应链攻击面，并确保库能够随 Zig 的演进而保持可维护性。

### 内存安全
- 每个堆分配的值都有对应的 `deinit()`。
- 大量使用 `errdefer` 防止错误路径上的内存泄漏。
- 单元测试在 `std.testing.allocator` 下运行，可自动检测泄漏。

### 并发模型
为 Zig 0.16.0 的 `std.Io` 抽象而构建：
- **Linux**：io_uring 后端实现真正的异步 I/O。
- **macOS/Windows/BSD**：基于工作窃取线程池的 Threaded 后端。
- Resolver 是在 `std.Io` 管理的纤程中运行的普通函数，无需显式的 `async/await` 语法。

## 模块职责

| 模块 | 职责 |
|------|------|
| `lexer.zig` | 将原始 GraphQL 文本转换为 `Token` 结构体流。处理字符串、数字、名称、标点和注释。 |
| `parser.zig` | 递归下降解析器，消费令牌并构建 `AST` (`Document`)。 |
| `ast.zig` | AST 节点定义（`Document`、`OperationDefinition`、`Field`、`SelectionSet` 等）。 |
| `schema.zig` | 运行时 schema 类型系统。定义 `Schema`、`Type`、`Field`、`TypeRef` 及内置指令。 |
| `schema_builder.zig` | `comptime` DSL，从 Zig 结构体字面量生成 GraphQL SDL。 |
| `schema_parser.zig` | 将 `.graphql` schema 定义语言文件解析为运行时 `Schema` 对象。 |
| `validator.zig` | 将解析后的 `Document` 对 `Schema` 进行校验。检查字段存在性、类型兼容性、片段循环和变量定义。 |
| `executor.zig` | 对 schema 执行已校验的查询。支持并行字段解析、部分错误和执行钩子。 |
| `introspection.zig` | 从运行时 schema 动态构建 `__Schema` 内省响应。 |
| `server.zig` | HTTP 服务器，含 GraphQL 端点、WebSocket 升级（`graphql-ws`）、CORS、健康检查和优雅关闭。 |
| `complexity.zig` | 在执行前分析查询深度和复杂度，防止 DoS。 |
| `query_cache.zig` | 基于 SHA-256 的查询缓存，用于持久化查询（APQ）和白名单。 |
| `metrics.zig` | 无锁指标收集，含查询数、耗时、错误率和每个 resolver 的计时。 |
| `dataloader.zig` | 请求级批量加载和缓存，解决 N+1 问题。 |
| `rate_limiter.zig` | 令牌桶速率限制器，使用整数运算保证生产稳定性。 |
| `response_cache.zig` | 基于 TTL 的内存响应缓存，用于可缓存查询。 |
| `audit_log.zig` | 结构化的 JSON Lines 审计日志，记录每个 GraphQL 请求。 |
| `tracing.zig` | 兼容 W3C traceparent 的分布式追踪，支持 OpenTelemetry 风格的 span 导出。 |
| `doc_generator.zig` | 从内省数据生成 Markdown API 文档。 |
