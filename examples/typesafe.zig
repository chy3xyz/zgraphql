/// TypeSafeSchemaBuilder Example
/// ============================================================================
/// Demonstrates zgraphql's compile-time type-safe schema DSL: resolvers are
/// declared inline with the schema definition using plain Zig types, and the
/// builder generates the bridging thunks at compile time (zero runtime cost).
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

/// Application context passed to every resolver as `ctx`.
const AppContext = struct {
    greeting: []const u8,
    scale: i64,
};

/// Resolver signatures:
///   - no args:      fn(ctx: *AppContext, allocator) anyerror!ReturnType
///   - with args:    fn(ctx: *AppContext, allocator, args: ArgsStruct) anyerror!ReturnType
/// Use `void` as the context type when no context is needed.
const Builder = zg.TypeSafeSchemaBuilder(AppContext, .{
    .Query = .{
        .hello = .{
            .type = "String!",
            .resolve = struct {
                fn resolve(ctx: *AppContext, alloc: std.mem.Allocator) anyerror![]const u8 {
                    return try alloc.dupe(u8, ctx.greeting);
                }
            }.resolve,
        },
        .double = .{
            .type = "Int!",
            .args = .{ .value = .{ .type = "Int!" } },
            .resolve = struct {
                const Args = struct { value: i64 };
                fn resolve(ctx: *AppContext, _: std.mem.Allocator, args: Args) anyerror!i64 {
                    return args.value * ctx.scale;
                }
            }.resolve,
        },
    },
});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // init() parses the generated SDL and binds all resolvers.
    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    var ctx = AppContext{ .greeting = "world", .scale = 3 };

    // Execute a query end-to-end.
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = zg.Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();
    executor.context.user_data = &ctx;

    const query = "{ hello double(value: 7) }";
    var parser = zg.Parser.init(allocator, query) catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit(allocator);

    const json_str = try result.toJson(allocator);
    defer allocator.free(json_str);

    std.debug.print("query: {s}\n", .{query});
    std.debug.print("result: {s}\n", .{json_str});
    std.debug.print("\nExpected: {{\"data\":{{\"hello\":\"world\",\"double\":21}}}}\n", .{});
}
