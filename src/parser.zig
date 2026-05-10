const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const ast = @import("ast.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var lexer = Lexer.init(allocator, source);
        const current = try lexer.nextToken();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = current,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.freeToken(&self.current);
    }

    pub fn parseDocument(self: *Parser) !ast.Document {
        var doc = ast.Document.init(self.allocator);
        errdefer doc.deinit();

        while (self.current.kind != .eof) {
            try doc.definitions.append(try self.parseDefinition());
        }
        return doc;
    }

    fn parseDefinition(self: *Parser) !ast.Definition {
        if (self.current.isKeyword("query") or
            self.current.isKeyword("mutation") or
            self.current.isKeyword("subscription")) {
            return .{ .operation = try self.parseOperationDefinition() };
        }
        if (self.current.isKeyword("fragment")) {
            return .{ .fragment = try self.parseFragmentDefinition() };
        }
        // Anonymous operation (shorthand query)
        if (self.current.kind == .lbrace) {
            var op = ast.OperationDefinition.init(self.allocator, .query, self.current.line, self.current.col);
            errdefer op.deinit(self.allocator);
            op.selection_set = try self.parseSelectionSet();
            return .{ .operation = op };
        }
        return error.UnexpectedToken;
    }

    fn parseOperationDefinition(self: *Parser) !ast.OperationDefinition {
        const op_type: ast.OperationType = switch (self.current.text[0]) {
            'q' => .query,
            'm' => .mutation,
            's' => .subscription,
            else => return error.InvalidOperationType,
        };
        try self.advance(); // consume keyword

        var op = ast.OperationDefinition.init(self.allocator, op_type, self.current.line, self.current.col);
        errdefer op.deinit(self.allocator);

        if (self.current.kind == .name) {
            op.name = self.current.text;
            try self.advance();
        }

        if (self.current.kind == .lparen) {
            op.variable_definitions = try self.parseVariableDefinitions();
        }

        op.directives = try self.parseDirectives();
        op.selection_set = try self.parseSelectionSet();
        return op;
    }

    fn parseFragmentDefinition(self: *Parser) !ast.FragmentDefinition {
        try self.expectKeyword("fragment");
        const name = try self.expectName();
        try self.expectKeyword("on");
        const type_condition = ast.NamedType{ .name = try self.expectName() };
        var frag = ast.FragmentDefinition.init(self.allocator, name, type_condition, self.current.line, self.current.col);
        errdefer frag.deinit(self.allocator);
        frag.directives = try self.parseDirectives();
        frag.selection_set = try self.parseSelectionSet();
        return frag;
    }

    fn parseVariableDefinitions(self: *Parser) !std.array_list.Managed(ast.VariableDefinition) {
        var list = std.array_list.Managed(ast.VariableDefinition).init(self.allocator);
        errdefer {
            for (list.items) |*vd| vd.deinit(self.allocator);
            list.deinit();
        }
        try self.expect(.lparen);
        while (self.current.kind != .rparen) {
            try list.append(try self.parseVariableDefinition());
        }
        try self.expect(.rparen);
        return list;
    }

    fn parseVariableDefinition(self: *Parser) !ast.VariableDefinition {
        try self.expect(.dollar);
        const name = try self.expectName();
        try self.expect(.colon);
        const var_type = try self.parseType();
        var vd = ast.VariableDefinition.init(self.allocator, name, var_type);
        errdefer vd.deinit(self.allocator);
        if (self.current.kind == .equals) {
            try self.advance();
            vd.default_value = try self.parseValue();
        }
        vd.directives = try self.parseDirectives();
        return vd;
    }

    const ParseError = std.mem.Allocator.Error || error{
        UnexpectedToken, ExpectedName, ExpectedKeyword,
        UnexpectedCharacter, UnterminatedString, InvalidEscape,
        InvalidCharacterInString, InvalidNumber,
        DuplicateField,
    };

    fn parseType(self: *Parser) ParseError!ast.Type {
        var result: ast.Type = undefined;
        if (self.current.kind == .lbracket) {
            try self.advance();
            const inner = try self.allocator.create(ast.Type);
            errdefer inner.deinit(self.allocator);
            inner.* = try self.parseType();
            try self.expect(.rbracket);
            result = .{ .list = inner };
        } else {
            result = .{ .named = .{ .name = try self.expectName() } };
        }
        if (self.current.kind == .bang) {
            try self.advance();
            const wrapped = try self.allocator.create(ast.Type);
            errdefer self.allocator.destroy(wrapped);
            wrapped.* = result;
            result = .{ .non_null = wrapped };
        }
        return result;
    }

    fn parseSelectionSet(self: *Parser) ParseError!ast.SelectionSet {
        var ss = ast.SelectionSet.init(self.allocator);
        errdefer ss.deinit(self.allocator);
        try self.expect(.lbrace);
        while (self.current.kind != .rbrace) {
            try ss.selections.append(try self.parseSelection());
        }
        try self.expect(.rbrace);
        return ss;
    }

    fn parseSelection(self: *Parser) ParseError!ast.Selection {
        if (self.current.kind == .spread) {
            try self.advance();
            if (self.current.isKeyword("on")) {
                try self.advance();
                var inline_frag = ast.InlineFragment.init(self.allocator, self.current.line, self.current.col);
                errdefer inline_frag.deinit(self.allocator);
                inline_frag.type_condition = ast.NamedType{ .name = try self.expectName() };
                inline_frag.directives = try self.parseDirectives();
                inline_frag.selection_set = try self.parseSelectionSet();
                return .{ .inline_fragment = inline_frag };
            }
            const name = try self.expectName();
            var fs = ast.FragmentSpread.init(self.allocator, name, self.current.line, self.current.col);
            errdefer fs.deinit(self.allocator);
            fs.directives = try self.parseDirectives();
            return .{ .fragment_spread = fs };
        }
        return .{ .field = try self.parseField() };
    }

    fn parseField(self: *Parser) !ast.Field {
        const name_or_alias = try self.expectName();
        var field = ast.Field.init(self.allocator, name_or_alias, self.current.line, self.current.col);
        errdefer field.deinit(self.allocator);

        if (self.current.kind == .colon) {
            try self.advance();
            field.alias = name_or_alias;
            field.name = try self.expectName();
        }

        if (self.current.kind == .lparen) {
            field.arguments = try self.parseArguments();
        }

        field.directives = try self.parseDirectives();

        if (self.current.kind == .lbrace) {
            field.selection_set = try self.parseSelectionSet();
        }
        return field;
    }

    fn parseArguments(self: *Parser) !std.array_list.Managed(ast.Argument) {
        var list = std.array_list.Managed(ast.Argument).init(self.allocator);
        errdefer {
            for (list.items) |*arg| arg.deinit(self.allocator);
            list.deinit();
        }
        try self.expect(.lparen);
        while (self.current.kind != .rparen) {
            const name = try self.expectName();
            try self.expect(.colon);
            try list.append(.{ .name = name, .value = try self.parseValue() });
        }
        try self.expect(.rparen);
        return list;
    }

    fn parseDirectives(self: *Parser) !std.array_list.Managed(ast.Directive) {
        var list = std.array_list.Managed(ast.Directive).init(self.allocator);
        errdefer {
            for (list.items) |*d| d.deinit(self.allocator);
            list.deinit();
        }
        while (self.current.kind == .at) {
            const line = self.current.line;
            const col = self.current.col;
            try self.advance();
            const name = try self.expectName();
            var dir = ast.Directive.init(self.allocator, name);
            errdefer dir.deinit(self.allocator);
            dir.line = line;
            dir.col = col;
            if (self.current.kind == .lparen) {
                dir.arguments = try self.parseArguments();
            }
            try list.append(dir);
        }
        return list;
    }

    fn parseValue(self: *Parser) ParseError!ast.AstValue {
        switch (self.current.kind) {
            .dollar => {
                try self.advance();
                const name = try self.expectName();
                return .{ .variable = name };
            },
            .int => {
                const text = self.current.text;
                try self.advance();
                return .{ .int_value = text };
            },
            .float => {
                const text = self.current.text;
                try self.advance();
                return .{ .float_value = text };
            },
            .string => {
                const text = try self.allocator.dupe(u8, self.current.text);
                try self.advance();
                return .{ .string_value = text };
            },
            .name => {
                const text = self.current.text;
                try self.advance();
                if (std.mem.eql(u8, text, "true")) return .{ .boolean_value = true };
                if (std.mem.eql(u8, text, "false")) return .{ .boolean_value = false };
                if (std.mem.eql(u8, text, "null")) return .{ .null_value = {} };
                return .{ .enum_value = text };
            },
            .lbracket => {
                try self.advance();
                var list = std.array_list.Managed(ast.AstValue).init(self.allocator);
                errdefer {
                    for (list.items) |*item| item.deinit(self.allocator);
                    list.deinit();
                }
                while (self.current.kind != .rbracket) {
                    try list.append(try self.parseValue());
                }
                try self.expect(.rbracket);
                return .{ .list_value = list };
            },
            .lbrace => {
                try self.advance();
                var obj = std.StringHashMap(ast.AstValue).init(self.allocator);
                errdefer {
                    var iter = obj.iterator();
                    while (iter.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(self.allocator);
                    }
                    obj.deinit();
                }
                while (self.current.kind != .rbrace) {
                    const key = try self.allocator.dupe(u8, try self.expectName());
                    try self.expect(.colon);
                    var value = self.parseValue() catch |err| {
                        self.allocator.free(key);
                        return err;
                    };
                    const gop = obj.getOrPut(key) catch |err| {
                        self.allocator.free(key);
                        value.deinit(self.allocator);
                        return err;
                    };
                    if (gop.found_existing) {
                        self.allocator.free(key);
                        value.deinit(self.allocator);
                        return error.DuplicateField;
                    }
                    gop.value_ptr.* = value;
                }
                try self.expect(.rbrace);
                return .{ .object_value = obj };
            },
            else => return error.UnexpectedToken,
        }
    }

    // Helpers

    fn advance(self: *Parser) !void {
        const new_token = try self.lexer.nextToken();
        self.freeToken(&self.current);
        self.current = new_token;
    }

    fn freeToken(self: *Parser, token: *Token) void {
        if (token.kind == .string or token.kind == .block_string) {
            self.allocator.free(token.text);
        }
    }

    fn expect(self: *Parser, kind: Token.Kind) !void {
        if (self.current.kind != kind) return error.UnexpectedToken;
        try self.advance();
    }

    fn expectName(self: *Parser) ![]const u8 {
        if (self.current.kind != .name) return error.ExpectedName;
        const text = self.current.text;
        try self.advance();
        return text;
    }

    fn expectKeyword(self: *Parser, kw: []const u8) !void {
        if (!self.current.isKeyword(kw)) return error.ExpectedKeyword;
        try self.advance();
    }
};

test "parser basic query" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator, "query { user(id: 1) { name email } }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.definitions.items.len);
    try std.testing.expect(doc.definitions.items[0].operation.op_type == .query);
}

test "parser fragment" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator,
        \\query {
        \\  user {
        \\    ...UserFields
        \\  }
        \\}
        \\fragment UserFields on User {
        \\  name
        \\  email
        \\}
    );
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.definitions.items.len);
}

test "parser variables and directives" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator,
        \\query GetUser($id: ID!, $includeEmail: Boolean = true) @auth {
        \\  user(id: $id) @cacheControl(maxAge: 3600) {
        \\    name
        \\    email @include(if: $includeEmail)
        \\  }
        \\}
    );
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const op = doc.definitions.items[0].operation;
    try std.testing.expectEqualStrings("GetUser", op.name.?);
    try std.testing.expectEqual(@as(usize, 2), op.variable_definitions.items.len);
    try std.testing.expectEqual(@as(usize, 1), op.directives.items.len);
}

test "parser inline fragment" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator,
        \\query {
        \\  node {
        \\    ... on User {
        \\      name
        \\    }
        \\    ... on Post {
        \\      title
        \\    }
        \\  }
        \\}
    );
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const op = doc.definitions.items[0].operation;
    const node_field = op.selection_set.selections.items[0].field;
    try std.testing.expectEqual(@as(usize, 2), node_field.selection_set.?.selections.items.len);
}

test "parser complex value" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator,
        \\query {
        \\  search(input: { query: "test", filters: [ACTIVE, ARCHIVED] })
        \\}
    );
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const op = doc.definitions.items[0].operation;
    const field = op.selection_set.selections.items[0].field;
    try std.testing.expectEqual(@as(usize, 1), field.arguments.items.len);
}

test "parser duplicate object field" {
    const allocator = std.testing.allocator;
    // Duplicate key "query" in input object should fail
    var parser = try Parser.init(allocator,
        \\{ search(input: { query: "a", query: "b" }) }
    );
    defer parser.deinit();
    try std.testing.expectError(error.DuplicateField, parser.parseDocument());
}
