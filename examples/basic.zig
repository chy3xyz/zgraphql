/// Basic Example
/// ============================================================================
/// This example demonstrates the core pipeline of zgraphql:
///   SchemaBuilder -> Parser -> Validator -> Introspection
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

pub fn main() !void {
    // Use a debug allocator to catch memory leaks during development.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Define schema using compile-time SchemaBuilder
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
    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    // Attach resolvers to schema fields.
    // Resolvers are plain Zig functions: (ctx, allocator, parent, args) -> Value
    if (schema_def.query_type.kind.object.fields.getPtr("hello")) |field| {
        field.resolve = struct {
            fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
                return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
            }
        }.resolve;
    }

    // 2. Parse query
    const query = "{ hello user { name email } }";
    var parser = try zg.Parser.init(allocator, query);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    // 3. Validate query against schema
    var validator = zg.Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const validation_result = try validator.validate(&doc);
    if (!validation_result.isValid()) {
        std.debug.print("Validation errors:\n", .{});
        for (validation_result.errors.items) |err| {
            std.debug.print("  - {s}\n", .{err.message});
        }
        return error.ValidationFailed;
    }

    // 4. Execution would happen here. In this example we just report success.
    std.debug.print("Query parsed and validated successfully!\n", .{});
    std.debug.print("Schema has {d} types registered.\n", .{schema_def.types.count()});
    std.debug.print("Document has {d} definitions.\n", .{doc.definitions.items.len});

    // 5. Introspection: generate the __Schema JSON response.
    var intro = try zg.Introspection.buildSchemaValue(allocator, &schema_def);
    defer intro.deinit(allocator);
    const json = try intro.toJson(allocator);
    defer allocator.free(json);
    std.debug.print("Introspection JSON:\n{s}\n", .{json});
}
