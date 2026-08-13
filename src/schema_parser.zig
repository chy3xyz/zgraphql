const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const schema = @import("schema.zig");
const Value = @import("value.zig").Value;

pub const SchemaParseError = error{
    UnexpectedToken,
    MissingQueryType,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidConstValue,
    InvalidEscape,
    InvalidCharacterInString,
    InvalidNumber,
} || std.mem.Allocator.Error;

/// Parses GraphQL Schema Definition Language (SDL) into a schema.Schema.
///
/// Supported:
///   schema { query: TypeName, mutation: TypeName, subscription: TypeName }
///   type TypeName implements Interface1, Interface2 { fields }
///   interface TypeName { fields }
///   enum TypeName { VALUE1, VALUE2 }
///   union TypeName = Type1 | Type2
///   input TypeName { fields }
///   scalar TypeName
///
pub const SchemaParser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !SchemaParser {
        var lexer = Lexer.init(allocator, source);
        const current = try lexer.nextToken();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = current,
        };
    }

    pub fn deinit(self: *SchemaParser) void {
        self.freeToken(&self.current);
    }

    fn freeToken(self: *SchemaParser, token: *Token) void {
        if (token.kind == .string or token.kind == .block_string) {
            self.allocator.free(token.text);
        }
    }

    pub fn parseSchema(self: *SchemaParser) SchemaParseError!schema.Schema {
        var types = std.StringHashMap(*schema.Type).init(self.allocator);
        errdefer {
            var iter = types.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
            }
        }
        defer types.deinit();

        var query_type_name: ?[]const u8 = null;
        var mutation_type_name: ?[]const u8 = null;
        var subscription_type_name: ?[]const u8 = null;
        var schema_description: ?[]const u8 = null;

        var directives = std.StringHashMap(schema.DirectiveDefinition).init(self.allocator);
        defer {
            var diter = directives.iterator();
            while (diter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            directives.deinit();
        }

        while (self.current.kind != .eof) {
            // Optional leading description (string or block_string) before a
            // type/directive definition. Ownership transfers to the parsed
            // definition on success; freed here on error.
            var description: ?[]const u8 = null;
            if (self.current.kind == .string or self.current.kind == .block_string) {
                description = try self.allocator.dupe(u8, self.current.text);
                try self.advance();
            }
            errdefer if (description) |d| self.allocator.free(d);

            if (self.current.isKeyword("schema")) {
                // Transfer the leading description into schema_description.
                schema_description = description;
                description = null;
                try self.parseSchemaDefinition(&query_type_name, &mutation_type_name, &subscription_type_name);
            } else if (self.current.isKeyword("type")) {
                const typ = try self.parseObjectType(description);
                try types.put(typ.name, typ);
            } else if (self.current.isKeyword("interface")) {
                const typ = try self.parseInterfaceType(description);
                try types.put(typ.name, typ);
            } else if (self.current.isKeyword("enum")) {
                const typ = try self.parseEnumType(description);
                try types.put(typ.name, typ);
            } else if (self.current.isKeyword("union")) {
                const typ = try self.parseUnionType(description);
                try types.put(typ.name, typ);
            } else if (self.current.isKeyword("input")) {
                const typ = try self.parseInputType(description);
                try types.put(typ.name, typ);
            } else if (self.current.isKeyword("scalar")) {
                const typ = try self.parseScalarType(description);
                try types.put(typ.name, typ);
            } else if (self.current.isKeyword("directive")) {
                try self.parseDirectiveDefinition(&directives, description);
            } else {
                return error.UnexpectedToken;
            }
        }

        // Resolve root types
        const qt = types.get(query_type_name orelse return error.MissingQueryType) orelse return error.MissingQueryType;
        var schema_def = try schema.Schema.init(self.allocator, qt);
        schema_def.description = schema_description;

        var iter = types.iterator();
        while (iter.next()) |entry| {
            try schema_def.registerType(entry.key_ptr.*, entry.value_ptr.*);
        }

        if (mutation_type_name) |name| {
            if (types.get(name)) |mt| schema_def.mutation_type = mt;
        }
        if (subscription_type_name) |name| {
            if (types.get(name)) |st| schema_def.subscription_type = st;
        }

        // Move custom directives into the schema (transfer ownership). The
        // local `directives` map is then cleared so its defer does not free
        // key/value pairs now owned by schema_def.directives.
        var diter = directives.iterator();
        while (diter.next()) |entry| {
            try schema_def.directives.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        directives.clearRetainingCapacity();

        return schema_def;
    }

    // --- Token helpers ---

    fn advance(self: *SchemaParser) SchemaParseError!void {
        const new_token = try self.lexer.nextToken();
        self.freeToken(&self.current);
        self.current = new_token;
    }

    fn check(self: *SchemaParser, kind: Token.Kind) bool {
        return self.current.kind == kind;
    }

    fn expect(self: *SchemaParser, kind: Token.Kind) SchemaParseError!void {
        if (!self.check(kind)) return error.UnexpectedToken;
        try self.advance();
    }

    fn expectName(self: *SchemaParser) SchemaParseError![]const u8 {
        if (self.current.kind != .name) return error.UnexpectedToken;
        const text = self.current.text;
        try self.advance();
        return text;
    }

    fn expectKeyword(self: *SchemaParser, kw: []const u8) SchemaParseError!void {
        if (!self.current.isKeyword(kw)) return error.UnexpectedToken;
        try self.advance();
    }

    // --- Definition parsers ---

    fn parseSchemaDefinition(
        self: *SchemaParser,
        query_name: *?[]const u8,
        mutation_name: *?[]const u8,
        subscription_name: *?[]const u8,
    ) SchemaParseError!void {
        try self.expectKeyword("schema");
        try self.expect(.lbrace);
        while (!self.check(.rbrace)) {
            const field_name = try self.expectName();
            try self.expect(.colon);
            const type_name = try self.expectName();
            if (std.mem.eql(u8, field_name, "query")) {
                query_name.* = type_name;
            } else if (std.mem.eql(u8, field_name, "mutation")) {
                mutation_name.* = type_name;
            } else if (std.mem.eql(u8, field_name, "subscription")) {
                subscription_name.* = type_name;
            }
            if (self.check(.rbrace)) break;
        }
        try self.expect(.rbrace);
    }

    fn parseObjectType(self: *SchemaParser, description: ?[]const u8) SchemaParseError!*schema.Type {
        try self.expectKeyword("type");
        const name = try self.expectName();

        var interfaces = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer interfaces.deinit();

        if (self.current.isKeyword("implements")) {
            try self.advance();
            while (true) {
                const iface = try self.expectName();
                try interfaces.append(iface);
                if (self.check(.amp)) {
                    try self.advance();
                } else {
                    break;
                }
            }
        }

        try self.expect(.lbrace);
        var obj_type = schema.ObjectType.init(self.allocator);
        errdefer obj_type.deinit(self.allocator);

        while (!self.check(.rbrace)) {
            const field = try self.parseFieldDefinition();
            // Dup the name for the HashMap key; Field.name points to source text
            try obj_type.fields.put(try self.allocator.dupe(u8, field.name), field);
        }
        try self.expect(.rbrace);

        const typ = try self.allocator.create(schema.Type);
        typ.* = .{
            .name = name,
            .description = description,
            .kind = .{ .object = obj_type },
        };
        typ.kind.object.interfaces = interfaces;
        return typ;
    }

    fn parseInterfaceType(self: *SchemaParser, description: ?[]const u8) SchemaParseError!*schema.Type {
        try self.expectKeyword("interface");
        const name = try self.expectName();

        try self.expect(.lbrace);
        var iface_type = schema.InterfaceType.init(self.allocator);
        errdefer iface_type.deinit(self.allocator);

        while (!self.check(.rbrace)) {
            const field = try self.parseFieldDefinition();
            try iface_type.fields.put(try self.allocator.dupe(u8, field.name), field);
        }
        try self.expect(.rbrace);

        const typ = try self.allocator.create(schema.Type);
        typ.* = .{
            .name = name,
            .description = description,
            .kind = .{ .interface = iface_type },
        };
        return typ;
    }

    fn parseEnumType(self: *SchemaParser, description: ?[]const u8) SchemaParseError!*schema.Type {
        try self.expectKeyword("enum");
        const name = try self.expectName();

        try self.expect(.lbrace);
        var enum_type = schema.EnumType.init(self.allocator);
        errdefer enum_type.deinit(self.allocator);

        while (!self.check(.rbrace)) {
            // Optional leading description per enum value.
            var val_desc: ?[]const u8 = null;
            if (self.current.kind == .string or self.current.kind == .block_string) {
                val_desc = try self.allocator.dupe(u8, self.current.text);
                try self.advance();
            }
            errdefer if (val_desc) |d| self.allocator.free(d);
            const val_name = try self.allocator.dupe(u8, try self.expectName());
            try enum_type.values.put(val_name, .{ .name = val_name, .description = val_desc });
            if (self.check(.rbrace)) break;
        }
        try self.expect(.rbrace);

        const typ = try self.allocator.create(schema.Type);
        typ.* = .{
            .name = name,
            .description = description,
            .kind = .{ .enum_type = enum_type },
        };
        return typ;
    }

    fn parseUnionType(self: *SchemaParser, description: ?[]const u8) SchemaParseError!*schema.Type {
        try self.expectKeyword("union");
        const name = try self.expectName();

        try self.expect(.equals);
        var union_type = schema.UnionType.init(self.allocator);
        errdefer union_type.deinit(self.allocator);

        while (true) {
            const member = try self.expectName();
            try union_type.possible_types.append(member);
            if (self.check(.pipe)) {
                try self.advance();
            } else {
                break;
            }
        }

        const typ = try self.allocator.create(schema.Type);
        typ.* = .{
            .name = name,
            .description = description,
            .kind = .{ .union_type = union_type },
        };
        return typ;
    }

    fn parseInputType(self: *SchemaParser, description: ?[]const u8) SchemaParseError!*schema.Type {
        try self.expectKeyword("input");
        const name = try self.expectName();

        try self.expect(.lbrace);
        var input_type = schema.InputObjectType.init(self.allocator);
        errdefer input_type.deinit(self.allocator);

        while (!self.check(.rbrace)) {
            const field_name = try self.expectName();
            try self.expect(.colon);
            const field_type = try self.parseTypeRef();
            const input_val = schema.InputValue{
                .name = field_name,
                .value_type = field_type,
            };
            try input_type.fields.put(try self.allocator.dupe(u8, field_name), input_val);
            if (self.check(.rbrace)) break;
        }
        try self.expect(.rbrace);

        const typ = try self.allocator.create(schema.Type);
        typ.* = .{
            .name = name,
            .description = description,
            .kind = .{ .input_object = input_type },
        };
        return typ;
    }

    fn parseScalarType(self: *SchemaParser, description: ?[]const u8) SchemaParseError!*schema.Type {
        try self.expectKeyword("scalar");
        const name = try self.expectName();

        const typ = try self.allocator.create(schema.Type);
        typ.* = .{
            .name = name,
            .description = description,
            .kind = .{ .scalar = .{} },
        };
        return typ;
    }

    /// Parse a directive definition:
    ///   directive @name(args) [repeatable] on LOCATION | LOCATION
    fn parseDirectiveDefinition(self: *SchemaParser, directives: *std.StringHashMap(schema.DirectiveDefinition), description: ?[]const u8) SchemaParseError!void {
        try self.expectKeyword("directive");
        try self.expect(.at);
        const name = try self.expectName();

        var def = schema.DirectiveDefinition.init(self.allocator, name);
        def.description = description;
        errdefer def.deinit(self.allocator);

        // Arguments
        if (self.check(.lparen)) {
            try self.advance();
            while (!self.check(.rparen)) {
                const arg_name = try self.expectName();
                try self.expect(.colon);
                const arg_type = try self.parseTypeRef();
                var default_value: ?Value = null;
                if (self.check(.equals)) {
                    try self.advance();
                    default_value = try self.parseConstValue();
                }
                const input_val = schema.InputValue{
                    .name = arg_name,
                    .value_type = arg_type,
                    .default_value = default_value,
                };
                try def.arguments.put(try self.allocator.dupe(u8, arg_name), input_val);
                if (self.check(.rparen)) break;
            }
            try self.expect(.rparen);
        }

        // Optional `repeatable`
        if (self.current.isKeyword("repeatable")) {
            def.is_repeatable = true;
            try self.advance();
        }

        // `on` + locations
        try self.expectKeyword("on");
        if (self.check(.pipe)) try self.advance();
        while (true) {
            const loc_name = try self.expectName();
            // SDL uses SCREAMING_SNAKE_CASE (e.g. FIELD_DEFINITION); the enum
            // is snake_case, so normalize before converting.
            var lower_buf: [64]u8 = undefined;
            if (loc_name.len > lower_buf.len) return error.UnexpectedToken;
            const lower = std.ascii.lowerString(&lower_buf, loc_name);
            const loc = std.meta.stringToEnum(schema.DirectiveLocation, lower) orelse return error.UnexpectedToken;
            try def.locations.append(loc);
            if (self.check(.pipe)) {
                try self.advance();
                continue;
            }
            break;
        }

        try directives.put(try self.allocator.dupe(u8, name), def);
    }

    fn parseFieldDefinition(self: *SchemaParser) SchemaParseError!schema.Field {
        // Optional leading description.
        var description: ?[]const u8 = null;
        if (self.current.kind == .string or self.current.kind == .block_string) {
            description = try self.allocator.dupe(u8, self.current.text);
            try self.advance();
        }
        errdefer if (description) |d| self.allocator.free(d);

        const name = try self.expectName();

        var field = schema.Field.init(self.allocator, name, schema.TypeRef.named(""));
        field.description = description;
        errdefer field.deinit(self.allocator);

        // Arguments
        if (self.check(.lparen)) {
            try self.advance();
            while (!self.check(.rparen)) {
                const arg_name = try self.expectName();
                try self.expect(.colon);
                const arg_type = try self.parseTypeRef();
                var default_value: ?Value = null;
                if (self.check(.equals)) {
                    try self.advance();
                    default_value = try self.parseConstValue();
                }
                const input_val = schema.InputValue{
                    .name = arg_name,
                    .value_type = arg_type,
                    .default_value = default_value,
                };
                try field.arguments.put(try self.allocator.dupe(u8, arg_name), input_val);
                if (self.check(.rparen)) break;
            }
            try self.expect(.rparen);
        }

        try self.expect(.colon);
        field.field_type = try self.parseTypeRef();

        // Directives on the field definition (e.g. @deprecated)
        while (self.check(.at)) {
            try self.parseFieldDirective(&field);
        }

        return field;
    }

    /// Parse a directive on a field definition (e.g. @deprecated(reason: "...")).
    fn parseFieldDirective(self: *SchemaParser, field: *schema.Field) SchemaParseError!void {
        try self.expect(.at);
        const name = try self.expectName();
        var args = std.StringHashMap(Value).init(self.allocator);
        defer {
            var iter = args.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            args.deinit();
        }
        if (self.check(.lparen)) {
            try self.advance();
            while (!self.check(.rparen)) {
                const arg_name = try self.expectName();
                try self.expect(.colon);
                const arg_value = try self.parseConstValue();
                try args.put(try self.allocator.dupe(u8, arg_name), arg_value);
                if (self.check(.rparen)) break;
            }
            try self.expect(.rparen);
        }
        if (std.mem.eql(u8, name, "deprecated")) {
            if (args.get("reason")) |reason| {
                field.deprecation_reason = try self.allocator.dupe(u8, reason.data.string);
            } else {
                field.deprecation_reason = try self.allocator.dupe(u8, "No longer supported");
            }
        }
    }

    /// Parse a constant (variable-free) value literal into a schema.Value.
    fn parseConstValue(self: *SchemaParser) SchemaParseError!Value {
        switch (self.current.kind) {
            .int => {
                const v = std.fmt.parseInt(i64, self.current.text, 10) catch return error.InvalidConstValue;
                try self.advance();
                return Value.fromInt(self.allocator, v);
            },
            .float => {
                const v = std.fmt.parseFloat(f64, self.current.text) catch return error.InvalidConstValue;
                try self.advance();
                return Value.fromFloat(self.allocator, v);
            },
            .string, .block_string => {
                const text = try self.allocator.dupe(u8, self.current.text);
                try self.advance();
                return Value.fromString(self.allocator, text);
            },
            .name => {
                const text = self.current.text;
                try self.advance();
                if (std.mem.eql(u8, text, "true")) return Value.fromBool(self.allocator, true);
                if (std.mem.eql(u8, text, "false")) return Value.fromBool(self.allocator, false);
                if (std.mem.eql(u8, text, "null")) return Value.fromNull(self.allocator);
                return Value.fromEnum(self.allocator, try self.allocator.dupe(u8, text));
            },
            .lbracket => {
                try self.advance();
                var list = Value.initList(self.allocator);
                errdefer list.deinit(self.allocator);
                while (!self.check(.rbracket)) {
                    try list.data.list.append(try self.parseConstValue());
                }
                try self.expect(.rbracket);
                return list;
            },
            .lbrace => {
                try self.advance();
                var obj = Value.initObject(self.allocator);
                errdefer obj.deinit(self.allocator);
                while (!self.check(.rbrace)) {
                    const key = try self.expectName();
                    try self.expect(.colon);
                    try obj.data.object.put(try self.allocator.dupe(u8, key), try self.parseConstValue());
                }
                try self.expect(.rbrace);
                return obj;
            },
            else => return error.InvalidConstValue,
        }
    }

    fn parseTypeRef(self: *SchemaParser) SchemaParseError!schema.TypeRef {
        var result: schema.TypeRef = undefined;

        if (self.check(.lbracket)) {
            try self.advance();
            const inner = try self.parseTypeRef();
            try self.expect(.rbracket);
            const inner_ptr = try self.allocator.create(schema.TypeRef);
            inner_ptr.* = inner;
            result = schema.TypeRef.list(inner_ptr);
        } else {
            const name = try self.expectName();
            result = schema.TypeRef.named(name);
        }

        if (self.check(.bang)) {
            try self.advance();
            const result_ptr = try self.allocator.create(schema.TypeRef);
            result_ptr.* = result;
            return schema.TypeRef.nonNull(result_ptr);
        }

        return result;
    }
};

test "schema parser basic" {
    const allocator = std.testing.allocator;

    const sdl =
        \\schema {
        \\  query: Query
        \\}
        \\
        \\type Query {
        \\  hello(name: String!): String!
        \\  user(id: ID!): User
        \\}
        \\
        \\type User {
        \\  id: ID!
        \\  name: String!
        \\  email: String
        \\}
    ;

    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var schema_def = try parser.parseSchema();
    defer schema_def.deinit();

    try std.testing.expectEqualStrings("Query", schema_def.query_type.name);
    try std.testing.expect(schema_def.getType("User") != null);

    const query_type = schema_def.query_type;
    try std.testing.expect(query_type.kind.object.fields.contains("hello"));
    try std.testing.expect(query_type.kind.object.fields.contains("user"));

    const hello_field = query_type.kind.object.fields.get("hello").?;
    try std.testing.expectEqualStrings("hello", hello_field.name);
    try std.testing.expect(hello_field.arguments.contains("name"));
}

test "schema parser enum and union" {
    const allocator = std.testing.allocator;

    const sdl =
        \\schema {
        \\  query: Query
        \\}
        \\
        \\type Query {
        \\  status: Status
        \\  search: SearchResult
        \\}
        \\
        \\enum Status {
        \\  ACTIVE
        \\  INACTIVE
        \\}
        \\
        \\union SearchResult = User
        \\
        \\type User {
        \\  id: ID!
        \\}
    ;

    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var schema_def = try parser.parseSchema();
    defer schema_def.deinit();

    const status_type = schema_def.getType("Status").?;
    try std.testing.expect(status_type.isEnum());
    try std.testing.expect(status_type.kind.enum_type.values.contains("ACTIVE"));

    const search_result = schema_def.getType("SearchResult").?;
    try std.testing.expect(search_result.isUnion());
}

test "schema parser interface and input" {
    const allocator = std.testing.allocator;

    const sdl =
        \\schema {
        \\  query: Query
        \\}
        \\
        \\type Query {
        \\  node(id: ID!): Node
        \\}
        \\
        \\interface Node {
        \\  id: ID!
        \\}
        \\
        \\type User implements Node {
        \\  id: ID!
        \\  name: String!
        \\}
        \\
        \\input CreateUserInput {
        \\  name: String!
        \\  email: String
        \\}
    ;

    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var schema_def = try parser.parseSchema();
    defer schema_def.deinit();

    const node_type = schema_def.getType("Node").?;
    try std.testing.expect(node_type.isInterface());
    try std.testing.expect(node_type.kind.interface.fields.contains("id"));

    const user_type = schema_def.getType("User").?;
    try std.testing.expect(user_type.isObject());
    try std.testing.expect(user_type.kind.object.interfaces.items.len > 0);

    const input_type = schema_def.getType("CreateUserInput").?;
    try std.testing.expect(input_type.isInputObject());
    try std.testing.expect(input_type.kind.input_object.fields.contains("name"));
}

test "schema parser list and non-null" {
    const allocator = std.testing.allocator;

    const sdl =
        \\schema {
        \\  query: Query
        \\}
        \\
        \\type Query {
        \\  users: [User!]!
        \\}
        \\
        \\type User {
        \\  id: ID!
        \\}
    ;

    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var schema_def = try parser.parseSchema();
    defer schema_def.deinit();

    const query_type = schema_def.query_type;
    const users_field = query_type.kind.object.fields.get("users").?;
    // [User!]! => non_null(list(non_null(User)))
    try std.testing.expect(users_field.field_type.isNonNull());
    try std.testing.expect(users_field.field_type.kind.non_null.*.isList());
    try std.testing.expect(users_field.field_type.kind.non_null.*.kind.list.*.isNonNull());
}

test "schema parser directive definition and arg default" {
    const allocator = std.testing.allocator;
    const sdl =
        \\schema { query: Query }
        \\directive @auth(role: String = "user") on FIELD_DEFINITION | OBJECT
        \\type Query {
        \\  hello(name: String = "world"): String
        \\}
    ;
    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var s = try parser.parseSchema();
    defer s.deinit();

    // Custom directive registered
    try std.testing.expect(s.getDirective("auth") != null);
    const d = s.getDirective("auth").?;
    try std.testing.expectEqual(@as(usize, 2), d.locations.items.len);

    // Argument default value parsed
    const field = s.query_type.getField("hello").?;
    const name_arg = field.arguments.get("name").?;
    try std.testing.expect(name_arg.default_value != null);
    try std.testing.expectEqualStrings("world", name_arg.default_value.?.data.string);
}

test "schema parser field deprecation" {
    const allocator = std.testing.allocator;
    const sdl =
        \\schema { query: Query }
        \\type Query {
        \\  old: String @deprecated(reason: "use new")
        \\}
    ;
    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var s = try parser.parseSchema();
    defer s.deinit();

    const field = s.query_type.getField("old").?;
    try std.testing.expect(field.deprecation_reason != null);
    try std.testing.expectEqualStrings("use new", field.deprecation_reason.?);
}

test "schema parser descriptions" {
    const allocator = std.testing.allocator;
    const sdl =
        \\"The query root"
        \\schema { query: Query }
        \\"A user type"
        \\type Query {
        \\  "Greets a user"
        \\  hello: String
        \\}
        \\"Role enum"
        \\enum Role {
        \\  "Administrator"
        \\  ADMIN
        \\  USER
        \\}
    ;
    var parser = try SchemaParser.init(allocator, sdl);
    defer parser.deinit();
    var s = try parser.parseSchema();
    defer s.deinit();

    try std.testing.expectEqualStrings("A user type", s.query_type.description.?);
    const hello = s.query_type.getField("hello").?;
    try std.testing.expectEqualStrings("Greets a user", hello.description.?);
    const role = s.getType("Role").?;
    try std.testing.expectEqualStrings("Role enum", role.description.?);
    try std.testing.expectEqualStrings("Administrator", role.kind.enum_type.values.get("ADMIN").?.description.?);
}
