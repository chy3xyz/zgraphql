const std = @import("std");

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    line: usize,
    col: usize,

    pub const Kind = enum {
        eof,
        name,
        int,
        float,
        string,
        block_string,
        // Punctuators
        bang,
        dollar,
        amp,
        lparen,
        rparen,
        spread,
        colon,
        equals,
        at,
        lbracket,
        rbracket,
        lbrace,
        pipe,
        rbrace,
    };

    pub fn isKeyword(self: Token, kw: []const u8) bool {
        return self.kind == .name and std.mem.eql(u8, self.text, kw);
    }
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn nextToken(self: *Lexer) !Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, "");
        }

        const start_line = self.line;
        const start_col = self.col;
        const c = self.source[self.pos];

        // Punctuators
        switch (c) {
            '!' => { self.advance(); return self.makeTokenAt(.bang, "!", start_line, start_col); },
            '$' => { self.advance(); return self.makeTokenAt(.dollar, "$", start_line, start_col); },
            '&' => { self.advance(); return self.makeTokenAt(.amp, "&", start_line, start_col); },
            '(' => { self.advance(); return self.makeTokenAt(.lparen, "(", start_line, start_col); },
            ')' => { self.advance(); return self.makeTokenAt(.rparen, ")", start_line, start_col); },
            ':' => { self.advance(); return self.makeTokenAt(.colon, ":", start_line, start_col); },
            '=' => { self.advance(); return self.makeTokenAt(.equals, "=", start_line, start_col); },
            '@' => { self.advance(); return self.makeTokenAt(.at, "@", start_line, start_col); },
            '[' => { self.advance(); return self.makeTokenAt(.lbracket, "[", start_line, start_col); },
            ']' => { self.advance(); return self.makeTokenAt(.rbracket, "]", start_line, start_col); },
            '{' => { self.advance(); return self.makeTokenAt(.lbrace, "{", start_line, start_col); },
            '}' => { self.advance(); return self.makeTokenAt(.rbrace, "}", start_line, start_col); },
            '|' => { self.advance(); return self.makeTokenAt(.pipe, "|", start_line, start_col); },
            '.' => {
                if (self.peekAhead(1) == '.' and self.peekAhead(2) == '.') {
                    self.advance(); self.advance(); self.advance();
                    return self.makeTokenAt(.spread, "...", start_line, start_col);
                }
                return error.UnexpectedCharacter;
            },
            '"' => {
                if (self.peekAhead(1) == '"' and self.peekAhead(2) == '"') {
                    return try self.readBlockString();
                }
                return try self.readString();
            },
            '-', '0'...'9' => return try self.readNumber(),
            else => {},
        }

        if (isNameStart(c)) {
            return try self.readName();
        }

        return error.UnexpectedCharacter;
    }

    fn readName(self: *Lexer) !Token {
        const start_line = self.line;
        const start_col = self.col;
        const start = self.pos;
        while (self.pos < self.source.len and isNameContinue(self.source[self.pos])) {
            self.advance();
        }
        return self.makeTokenAt(.name, self.source[start..self.pos], start_line, start_col);
    }

    fn readNumber(self: *Lexer) !Token {
        const start_line = self.line;
        const start_col = self.col;
        const start = self.pos;

        // Optional minus
        if (self.peek() == '-') {
            self.advance();
        }

        // Integer part
        if (self.peek() == '0') {
            self.advance();
        } else if (std.ascii.isDigit(self.peek())) {
            while (std.ascii.isDigit(self.peek())) {
                self.advance();
            }
        } else {
            return error.InvalidNumber;
        }

        var is_float = false;

        // Fractional part
        if (self.peek() == '.') {
            is_float = true;
            self.advance();
            if (!std.ascii.isDigit(self.peek())) return error.InvalidNumber;
            while (std.ascii.isDigit(self.peek())) {
                self.advance();
            }
        }

        // Exponent part
        if (self.peek() == 'E' or self.peek() == 'e') {
            is_float = true;
            self.advance();
            if (self.peek() == '+' or self.peek() == '-') {
                self.advance();
            }
            if (!std.ascii.isDigit(self.peek())) return error.InvalidNumber;
            while (std.ascii.isDigit(self.peek())) {
                self.advance();
            }
        }

        const text = self.source[start..self.pos];
        return self.makeTokenAt(if (is_float) .float else .int, text, start_line, start_col);
    }

    fn readString(self: *Lexer) !Token {
        const start_line = self.line;
        const start_col = self.col;

        self.advance(); // opening "
        var result = std.array_list.Managed(u8).init(self.allocator);
        errdefer result.deinit();

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.advance();
                break;
            }
            if (c == '\\') {
                self.advance();
                if (self.pos >= self.source.len) return error.UnterminatedString;
                const esc = self.source[self.pos];
                switch (esc) {
                    '"' => try result.append('"'),
                    '\\' => try result.append('\\'),
                    '/' => try result.append('/'),
                    'b' => try result.append('\x08'),
                    'f' => try result.append('\x0c'),
                    'n' => try result.append('\n'),
                    'r' => try result.append('\r'),
                    't' => try result.append('\t'),
                    'u' => {
                        self.advance();
                        if (self.pos + 4 > self.source.len) return error.InvalidEscape;
                        const hex = self.source[self.pos..self.pos + 4];
                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscape;
                        try appendUtf8Codepoint(&result, codepoint);
                        self.pos += 3;
                        self.col += 3;
                    },
                    else => return error.InvalidEscape,
                }
            } else if (c < 0x20) {
                return error.InvalidCharacterInString;
            } else {
                try result.append(c);
            }
            self.advance();
        }

        const text = try result.toOwnedSlice();
        return Token{ .kind = .string, .text = text, .line = start_line, .col = start_col };
    }

    fn readBlockString(self: *Lexer) !Token {
        const start_line = self.line;
        const start_col = self.col;

        self.advance(); self.advance(); self.advance(); // opening """

        const content_start = self.pos;
        while (self.pos + 3 <= self.source.len) {
            if (self.source[self.pos] == '"' and
                self.source[self.pos + 1] == '"' and
                self.source[self.pos + 2] == '"') {
                self.advance(); self.advance(); self.advance();
                const raw = self.source[content_start .. self.pos - 3];
                // Simple block string processing: strip common leading whitespace
                const text = try self.allocator.dupe(u8, std.mem.trim(u8, raw, &std.ascii.whitespace));
                return Token{ .kind = .block_string, .text = text, .line = start_line, .col = start_col };
            }
            self.advance();
        }
        return error.UnterminatedString;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == ',') {
                self.advance();
            } else if (c == '\n') {
                self.advance();
                self.line += 1;
                self.col = 1;
            } else if (c == '#') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
            self.col += 1;
        }
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAhead(self: *Lexer, offset: usize) u8 {
        if (self.pos + offset >= self.source.len) return 0;
        return self.source[self.pos + offset];
    }

    fn makeToken(self: *Lexer, kind: Token.Kind, text: []const u8) Token {
        return self.makeTokenAt(kind, text, self.line, self.col);
    }

    fn makeTokenAt(self: *Lexer, kind: Token.Kind, text: []const u8, line: usize, col: usize) Token {
        _ = self;
        return .{ .kind = kind, .text = text, .line = line, .col = col };
    }
};

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isNameContinue(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c);
}

fn appendUtf8Codepoint(list: *std.array_list.Managed(u8), codepoint: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return error.InvalidEscape;
    try list.appendSlice(buf[0..len]);
}

test "lexer basic tokens" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "query { user(id: 1) { name email } }");

    const expected = [_]Token.Kind{ .name, .lbrace, .name, .lparen, .name, .colon, .int, .rparen, .lbrace, .name, .name, .rbrace, .rbrace, .eof };
    for (expected) |kind| {
        const tok = try lexer.nextToken();
        if (tok.kind == .string or tok.kind == .block_string) allocator.free(tok.text);
        try std.testing.expectEqual(kind, tok.kind);
    }
}

test "lexer string" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "\"hello\\nworld\"");
    const tok = try lexer.nextToken();
    defer if (tok.kind == .string) allocator.free(tok.text);
    try std.testing.expectEqual(.string, tok.kind);
    try std.testing.expectEqualStrings("hello\nworld", tok.text);
}

test "lexer number" {
    const allocator = std.testing.allocator;

    var l1 = Lexer.init(allocator, "42");
    const t1 = try l1.nextToken();
    try std.testing.expectEqual(.int, t1.kind);
    try std.testing.expectEqualStrings("42", t1.text);

    var l2 = Lexer.init(allocator, "-3.14");
    const t2 = try l2.nextToken();
    try std.testing.expectEqual(.float, t2.kind);
    try std.testing.expectEqualStrings("-3.14", t2.text);

    var l3 = Lexer.init(allocator, "1e10");
    const t3 = try l3.nextToken();
    try std.testing.expectEqual(.float, t3.kind);
    try std.testing.expectEqualStrings("1e10", t3.text);
}

test "lexer comments" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "# this is a comment\nquery");
    const tok = try lexer.nextToken();
    try std.testing.expectEqual(.name, tok.kind);
    try std.testing.expectEqualStrings("query", tok.text);
}

test "lexer punctuators" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(allocator, "!$&()...:=@[]{}|");
    const kinds = [_]Token.Kind{ .bang, .dollar, .amp, .lparen, .rparen, .spread, .colon, .equals, .at, .lbracket, .rbracket, .lbrace, .rbrace, .pipe, .eof };
    for (kinds) |kind| {
        const tok = try lexer.nextToken();
        try std.testing.expectEqual(kind, tok.kind);
    }
}
