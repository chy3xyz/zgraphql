const std = @import("std");
const ast = @import("ast.zig");

/// Analyzes query complexity and depth.
pub const ComplexityAnalyzer = struct {
    pub const Result = struct {
        depth: usize,
        complexity: usize,
    };

    pub fn analyzeDocument(doc: *ast.Document) Result {
        var max_depth: usize = 0;
        var total_complexity: usize = 0;

        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .operation => |*op| {
                    const r = analyzeSelectionSet(&op.selection_set);
                    max_depth = @max(max_depth, r.depth);
                    total_complexity += r.complexity;
                },
                .fragment => |*frag| {
                    const r = analyzeSelectionSet(&frag.selection_set);
                    max_depth = @max(max_depth, r.depth);
                    total_complexity += r.complexity;
                },
            }
        }

        return .{ .depth = max_depth, .complexity = total_complexity };
    }

    fn analyzeSelectionSet(ss: *ast.SelectionSet) Result {
        var max_child_depth: usize = 0;
        var total_complexity: usize = 0;

        for (ss.selections.items) |*sel| {
            const r = analyzeSelection(sel);
            max_child_depth = @max(max_child_depth, r.depth);
            total_complexity += r.complexity;
        }

        // Selection set depth = max depth of its selections (no extra +1)
        return .{
            .depth = max_child_depth,
            .complexity = total_complexity,
        };
    }

    fn analyzeSelection(sel: *ast.Selection) Result {
        switch (sel.*) {
            .field => |*field| {
                var complexity: usize = 1; // base cost for a field
                complexity += field.arguments.items.len;

                if (field.selection_set) |*fss| {
                    const child = analyzeSelectionSet(fss);
                    return .{
                        .depth = 1 + child.depth,
                        .complexity = complexity + child.complexity,
                    };
                }
                return .{ .depth = 1, .complexity = complexity };
            },
            .fragment_spread => {
                return .{ .depth = 1, .complexity = 1 };
            },
            .inline_fragment => |*ifrag| {
                const child = analyzeSelectionSet(&ifrag.selection_set);
                return .{
                    .depth = 1 + child.depth,
                    .complexity = 1 + child.complexity,
                };
            },
        }
    }
};

/// Query depth limit validator.
pub const DepthLimit = struct {
    max_depth: usize,

    pub fn check(self: DepthLimit, doc: *ast.Document) ?usize {
        const result = ComplexityAnalyzer.analyzeDocument(doc);
        if (result.depth > self.max_depth) {
            return result.depth;
        }
        return null;
    }
};

/// Query complexity limit validator.
pub const ComplexityLimit = struct {
    max_complexity: usize,

    pub fn check(self: ComplexityLimit, doc: *ast.Document) ?usize {
        const result = ComplexityAnalyzer.analyzeDocument(doc);
        if (result.complexity > self.max_complexity) {
            return result.complexity;
        }
        return null;
    }
};

test "complexity basic" {
    const allocator = std.testing.allocator;
    const source = "{ user { name email posts { title author { name } } } }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const result = ComplexityAnalyzer.analyzeDocument(&doc);
    try std.testing.expectEqual(@as(usize, 4), result.depth); // user(1)->posts(2)->author(3)->name(4)
    try std.testing.expect(result.complexity > 0);
}

test "depth limit" {
    const allocator = std.testing.allocator;
    const source = "{ user { name } }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const limit = DepthLimit{ .max_depth = 2 };
    try std.testing.expect(limit.check(&doc) == null);

    const strict = DepthLimit{ .max_depth = 1 };
    try std.testing.expect(strict.check(&doc) != null);
}

test "complexity limit" {
    const allocator = std.testing.allocator;
    const source = "{ user { name email posts { title author { name } } } }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const result = ComplexityAnalyzer.analyzeDocument(&doc);

    const limit = ComplexityLimit{ .max_complexity = result.complexity + 10 };
    try std.testing.expect(limit.check(&doc) == null);

    const strict = ComplexityLimit{ .max_complexity = 1 };
    try std.testing.expect(strict.check(&doc) != null);
}
