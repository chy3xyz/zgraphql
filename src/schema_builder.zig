const std = @import("std");
const SchemaParser = @import("schema_parser.zig").SchemaParser;
const schema = @import("schema.zig");

/// Compile-time GraphQL schema definition DSL.
///
/// Generates a GraphQL SDL string at compile time from a structured Zig literal,
/// then parses it into a runtime `Schema` on demand.
///
/// Example:
/// ```zig
/// const Builder = comptime zg.SchemaBuilder(.{
///     .Query = .{
///         .hello = .{ .type = "String!" },
///         .user = .{ .type = "User", .args = .{ .id = .{ .type = "ID!" } } },
///     },
///     .User = .{
///         .name = .{ .type = "String!" },
///         .email = .{ .type = "String" },
///     },
/// });
/// const sdl = Builder.sdl; // comptime-known string
/// var parsed_schema = try Builder.init(allocator);
/// ```
pub fn SchemaBuilder(comptime def: anytype) type {
    const Def = @TypeOf(def);
    comptime validateDef(Def);
    const sdl_string = comptime generateSDL(def);

    return struct {
        /// The generated GraphQL SDL string (compile-time known).
        pub const sdl: []const u8 = sdl_string;

        /// Parse the generated SDL into a runtime Schema.
        pub fn init(allocator: std.mem.Allocator) !schema.Schema {
            var parser = try SchemaParser.init(allocator, sdl);
            defer parser.deinit();
            return try parser.parseSchema();
        }
    };
}

/// Validate that `Def` is a struct where each field represents a GraphQL type,
/// and each nested field represents a GraphQL field definition.
fn validateDef(comptime Def: type) void {
    const info = @typeInfo(Def);
    if (info != .@"struct") {
        @compileError("SchemaBuilder expects a struct literal, got " ++ @typeName(Def));
    }

    inline for (info.@"struct".fields) |type_field| {
        const TypeDef = type_field.type;
        const type_info = @typeInfo(TypeDef);
        if (type_info != .@"struct") {
            @compileError("SchemaBuilder type '" ++ type_field.name ++ "' must be a struct of fields");
        }

        inline for (type_info.@"struct".fields) |field_def| {
            const FieldType = field_def.type;
            const field_info = @typeInfo(FieldType);
            if (field_info != .@"struct") {
                @compileError("SchemaBuilder field '" ++ type_field.name ++ "." ++ field_def.name ++ "' must be a struct with at least .type");
            }

            // Check that .type exists
            const has_type = blk: {
                var found = false;
                for (field_info.@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, "type")) {
                        found = true;
                        break;
                    }
                }
                break :blk found;
            };
            if (!has_type) {
                @compileError("SchemaBuilder field '" ++ type_field.name ++ "." ++ field_def.name ++ "' is missing required .type");
            }
        }
    }
}

/// Generate SDL string from the compile-time definition using string concatenation.
fn generateSDL(comptime def: anytype) []const u8 {
    var result: []const u8 = "";
    const Def = @TypeOf(def);
    const info = @typeInfo(Def);
    var has_query = false;
    inline for (info.@"struct".fields) |type_field| {
        if (std.mem.eql(u8, type_field.name, "Query")) has_query = true;
    }

    inline for (info.@"struct".fields) |type_field| {
        const type_name = type_field.name;
        const type_value = @field(def, type_name);

        result = result ++ "type " ++ type_name ++ " {\n";

        const TypeDef = @TypeOf(type_value);
        const type_info = @typeInfo(TypeDef);
        inline for (type_info.@"struct".fields) |field_def| {
            const field_name = field_def.name;
            const field_value = @field(type_value, field_name);

            // Extract type string, args, and description
            var type_str: []const u8 = "";
            var args_str: []const u8 = "";
            var description: []const u8 = "";
            const FieldType = @TypeOf(field_value);
            const field_info = @typeInfo(FieldType);
            inline for (field_info.@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "type")) {
                    type_str = @field(field_value, "type");
                }
                if (std.mem.eql(u8, f.name, "args")) {
                    args_str = generateArgsSDL(@field(field_value, "args"));
                }
                if (std.mem.eql(u8, f.name, "description")) {
                    description = @field(field_value, "description");
                }
            }

            if (description.len > 0) {
                result = result ++ "  \"\"\"\n  " ++ description ++ "\n  \"\"\"\n";
            }
            result = result ++ "  " ++ field_name ++ args_str ++ ": " ++ type_str ++ "\n";
        }

        result = result ++ "}\n\n";
    }

    // Add schema definition if Query type exists
    if (has_query) {
        result = result ++ "schema {\n  query: Query\n}\n";
    }

    return result;
}

/// Generate arguments SDL from an args struct instance.
fn generateArgsSDL(comptime args: anytype) []const u8 {
    var result: []const u8 = "(";
    const Args = @TypeOf(args);
    const info = @typeInfo(Args);
    var first = true;
    inline for (info.@"struct".fields) |arg_field| {
        if (!first) result = result ++ ", ";
        first = false;

        const arg_name = arg_field.name;
        const arg_value = @field(args, arg_name);

        var arg_type_str: []const u8 = "";
        const ArgType = @TypeOf(arg_value);
        const arg_info = @typeInfo(ArgType);
        inline for (arg_info.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "type")) {
                arg_type_str = @field(arg_value, "type");
            }
        }

        result = result ++ arg_name ++ ": " ++ arg_type_str;
    }
    result = result ++ ")";
    return result;
}

test "SchemaBuilder generates SDL" {
    comptime {
        @setEvalBranchQuota(10000);
        const Builder = SchemaBuilder(.{
            .Query = .{
                .hello = .{ .type = "String!", .description = "A greeting" },
                .user = .{ .type = "User", .args = .{ .id = .{ .type = "ID!" } } },
            },
            .User = .{
                .name = .{ .type = "String!" },
                .email = .{ .type = "String" },
            },
        });

        try std.testing.expect(Builder.sdl.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "type Query") != null);
        try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "hello: String!") != null);
        try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "user(id: ID!): User") != null);
        try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "type User") != null);
        try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "A greeting") != null);
    }
}

test "SchemaBuilder init parses SDL" {
    const Builder = comptime SchemaBuilder(.{
        .Query = .{
            .hello = .{ .type = "String!" },
        },
    });

    const allocator = std.testing.allocator;
    var s = try Builder.init(allocator);
    defer s.deinit();

    try std.testing.expectEqualStrings("Query", s.query_type.name);
    try std.testing.expect(s.getType("Query") != null);
}
