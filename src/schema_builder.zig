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

        // Skip validation for types with explicit kind (scalar, enum, union etc.) and auto-enums
        if (comptime isAutoEnum(TypeDef) or hasExplicitKind(TypeDef)) continue;

        // Object/interface/input: each field (except meta) must have .type
        inline for (type_info.@"struct".fields) |field_def| {
            if (std.mem.eql(u8, field_def.name, "kind") or std.mem.eql(u8, field_def.name, "implements")) continue;

            const FieldType = field_def.type;
            const field_info = @typeInfo(FieldType);
            if (field_info != .@"struct") {
                @compileError("SchemaBuilder field '" ++ type_field.name ++ "." ++ field_def.name ++ "' must be a struct with at least .type");
            }
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

/// Check if the type definition has an explicit .kind field.
fn hasExplicitKind(comptime TypeDef: type) bool {
    const type_info = @typeInfo(TypeDef);
    if (type_info != .@"struct") return false;
    inline for (type_info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "kind")) return true;
    }
    return false;
}

/// Detect whether the type definition is an enum (all fields lack .type, and no explicit .kind).
fn isAutoEnum(comptime TypeDef: type) bool {
    const type_info = @typeInfo(TypeDef);
    if (type_info != .@"struct" or type_info.@"struct".fields.len == 0) return false;
    if (hasExplicitKind(TypeDef)) return false;

    var all_enum = true;
    inline for (type_info.@"struct".fields) |field_def| {
        const FieldType = field_def.type;
        const field_info = @typeInfo(FieldType);
        if (field_info == .@"struct") {
            inline for (field_info.@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "type")) {
                    all_enum = false;
                }
            }
        } else {
            all_enum = false;
        }
    }
    return all_enum;
}

/// Get the type kind: "scalar", "enum", "interface", "input", or "type".
/// Needs the actual value to read the .kind field.
fn resolveKind(comptime type_value: anytype) []const u8 {
    if (comptime isAutoEnum(@TypeOf(type_value))) return "enum";
    if (comptime hasExplicitKind(@TypeOf(type_value))) {
        return @field(type_value, "kind");
    }
    return "type";
}

/// Extract .implements value from type definition, or empty string.
fn getImplements(comptime TypeDef: type, comptime type_value: anytype) []const u8 {
    const type_info = @typeInfo(TypeDef);
    inline for (type_info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "implements")) {
            return @field(type_value, "implements");
        }
    }
    return "";
}

/// Generate SDL string from the compile-time definition using string concatenation.
fn generateSDL(comptime def: anytype) []const u8 {
    @setEvalBranchQuota(10000);
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
        const TypeDef = @TypeOf(type_value);
        const type_info = @typeInfo(TypeDef);
        const kind = comptime resolveKind(type_value);
        const implements_str = comptime getImplements(TypeDef, type_value);

        if (std.mem.eql(u8, kind, "scalar")) {
            result = result ++ "scalar " ++ type_name ++ "\n\n";
            continue;
        }

        if (std.mem.eql(u8, kind, "union")) {
            var members_str: []const u8 = "";
            inline for (type_info.@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "members")) {
                    members_str = @field(type_value, "members");
                }
            }
            result = result ++ "union " ++ type_name ++ " = " ++ members_str ++ "\n\n";
            continue;
        }

        if (std.mem.eql(u8, kind, "enum")) {
            result = result ++ "enum " ++ type_name ++ " {\n";
            inline for (type_info.@"struct".fields) |field_def| {
                const field_name = field_def.name;
                if (std.mem.eql(u8, field_name, "kind")) continue;
                const field_value = @field(type_value, field_name);
                var description: []const u8 = "";
                const FieldType = @TypeOf(field_value);
                const field_info = @typeInfo(FieldType);
                if (field_info == .@"struct") {
                    inline for (field_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "description")) {
                            description = @field(field_value, "description");
                        }
                    }
                }
                if (description.len > 0) {
                    result = result ++ "  \"\"\"\n  " ++ description ++ "\n  \"\"\"\n";
                }
                result = result ++ "  " ++ field_name ++ "\n";
            }
            result = result ++ "}\n\n";
            continue;
        }

        // Object, interface, or input types with fields
        result = result ++ kind ++ " " ++ type_name;
        if (implements_str.len > 0) {
            result = result ++ " implements " ++ implements_str;
        }
        result = result ++ " {\n";

        inline for (type_info.@"struct".fields) |field_def| {
            const field_name = field_def.name;
            // Skip meta-fields
            if (std.mem.eql(u8, field_name, "kind") or std.mem.eql(u8, field_name, "implements")) continue;
            const field_value = @field(type_value, field_name);

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
    var has_mutation = false;
    var has_subscription = false;
    inline for (info.@"struct".fields) |type_field| {
        if (std.mem.eql(u8, type_field.name, "Mutation")) has_mutation = true;
        if (std.mem.eql(u8, type_field.name, "Subscription")) has_subscription = true;
    }

    if (has_query or has_mutation or has_subscription) {
        result = result ++ "schema {\n";
        if (has_query) result = result ++ "  query: Query\n";
        if (has_mutation) result = result ++ "  mutation: Mutation\n";
        if (has_subscription) result = result ++ "  subscription: Subscription\n";
        result = result ++ "}\n";
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

test "SchemaBuilder enum and interface" {
    const Builder = comptime SchemaBuilder(.{
        .Query = .{
            .user = .{ .type = "User" },
            .status = .{ .type = "Status" },
        },
        .User = .{
            .name = .{ .type = "String!" },
        },
        .Status = .{
            .kind = "enum",
            .ACTIVE = .{},
            .INACTIVE = .{},
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "enum Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "ACTIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "INACTIVE") != null);

    // Parse and verify
    const allocator = std.testing.allocator;
    var s = try Builder.init(allocator);
    defer s.deinit();

    const status_type = s.getType("Status").?;
    try std.testing.expect(status_type.isEnum());
    try std.testing.expect(status_type.kind.enum_type.values.contains("ACTIVE"));
}

test "SchemaBuilder interface with implements" {
    const Builder = comptime SchemaBuilder(.{
        .Query = .{
            .node = .{ .type = "Node" },
        },
        .Node = .{
            .kind = "interface",
            .id = .{ .type = "ID!" },
        },
        .User = .{
            .implements = "Node",
            .id = .{ .type = "ID!" },
            .name = .{ .type = "String!" },
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "interface Node") != null);
    try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "implements Node") != null);

    const allocator = std.testing.allocator;
    var s = try Builder.init(allocator);
    defer s.deinit();

    const node_type = s.getType("Node").?;
    try std.testing.expect(node_type.isInterface());

    const user_type = s.getType("User").?;
    try std.testing.expect(user_type.isObject());
    try std.testing.expect(user_type.kind.object.interfaces.items.len > 0);
}

test "SchemaBuilder scalar" {
    const Builder = comptime SchemaBuilder(.{
        .Query = .{
            .date = .{ .type = "Date" },
        },
        .Date = .{
            .kind = "scalar",
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, Builder.sdl, "scalar Date") != null);

    const allocator = std.testing.allocator;
    var s = try Builder.init(allocator);
    defer s.deinit();

    const date_type = s.getType("Date").?;
    try std.testing.expect(date_type.isScalar());
}
