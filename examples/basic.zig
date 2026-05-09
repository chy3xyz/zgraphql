/// ============================================================================
/// Basic Example / 基础示例
/// ============================================================================
/// This example demonstrates the core pipeline of zgraphql:
///   SchemaBuilder -> Parser -> Validator -> Introspection
///
/// 本示例展示了 zgraphql 的核心处理流程：
///   构建 Schema -> 解析查询 -> 校验查询 -> 内省
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

pub fn main() !void {
    // Use a debug allocator to catch memory leaks during development.
    // 开发阶段使用 DebugAllocator 以检测内存泄漏。
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Define schema using compile-time SchemaBuilder / 使用编译期 SchemaBuilder 定义 schema
    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
            .user = .{ .type = "User" },
        },
        .User = .{
            .name = .{ .type = "String!" },
            .email = .{ .type = "String" },
        },
    });

    std.debug.print("Generated SDL:\n{s}\n\n", .{Builder.sdl});

    // Initialize the runtime schema from the builder.
    // 从 builder 初始化运行时 schema。
    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    // Attach resolvers to schema fields.
    // Resolvers are plain Zig functions: (ctx, allocator, parent, args) -> Value
    // 为 schema 字段附加 resolver。
    // Resolver 是普通 Zig 函数：(ctx, allocator, parent, args) -> Value
    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // 2. Parse query / 解析查询
    const query = "{ hello user { name email } }";
    var parser = try zg.Parser.init(allocator, query);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    // 3. Validate query against schema / 校验查询
    var validator = zg.Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const validation_result = try validator.validate(&doc);
    if (!validation_result.isValid()) {
        std.debug.print("Validation errors / 校验错误:\n", .{});
        for (validation_result.errors.items) |err| {
            std.debug.print("  - {s}\n", .{err.message});
        }
        return error.ValidationFailed;
    }

    // 4. Execution would happen here. In this example we just report success.
    // 实际执行将在这里发生。本示例仅报告成功。
    std.debug.print("Query parsed and validated successfully! / 查询解析和校验成功！\n", .{});
    std.debug.print("Schema has {d} types registered. / Schema 已注册 {d} 个类型。\n", .{ schema_def.types.count(), schema_def.types.count() });
    std.debug.print("Document has {d} definitions. / 文档包含 {d} 个定义。\n", .{ doc.definitions.items.len, doc.definitions.items.len });

    // 5. Introspection: generate the __Schema JSON response.
    // 内省：生成 __Schema JSON 响应。
    var intro = try zg.Introspection.buildSchemaValue(allocator, &schema_def);
    defer intro.deinit();
    const json = try intro.toJson();
    defer allocator.free(json);
    std.debug.print("Introspection JSON:\n{s}\n", .{json});
}
