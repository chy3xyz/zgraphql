const std = @import("std");
const Value = @import("value.zig").Value;

/// GraphQL AST node types.

pub const Document = struct {
    allocator: std.mem.Allocator,
    definitions: std.array_list.Managed(Definition),

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .definitions = std.array_list.Managed(Definition).init(allocator),
        };
    }

    pub fn deinit(self: *Document) void {
        for (self.definitions.items) |*def| {
            def.deinit(self.allocator);
        }
        self.definitions.deinit();
    }
};

pub const Definition = union(enum) {
    operation: OperationDefinition,
    fragment: FragmentDefinition,

    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .operation => |*op| op.deinit(allocator),
            .fragment => |*frag| frag.deinit(allocator),
        }
    }
};

pub const OperationDefinition = struct {
    op_type: OperationType,
    name: ?[]const u8 = null,
    variable_definitions: std.array_list.Managed(VariableDefinition),
    directives: std.array_list.Managed(Directive),
    selection_set: SelectionSet,
    line: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, op_type: OperationType, line: usize, col: usize) OperationDefinition {
        return .{
            .op_type = op_type,
            .variable_definitions = std.array_list.Managed(VariableDefinition).init(allocator),
            .directives = std.array_list.Managed(Directive).init(allocator),
            .selection_set = SelectionSet.init(allocator),
            .line = line,
            .col = col,
        };
    }

    pub fn deinit(self: *OperationDefinition, allocator: std.mem.Allocator) void {
        for (self.variable_definitions.items) |*vd| vd.deinit(allocator);
        self.variable_definitions.deinit();
        for (self.directives.items) |*d| d.deinit(allocator);
        self.directives.deinit();
        self.selection_set.deinit(allocator);
    }
};

pub const OperationType = enum {
    query,
    mutation,
    subscription,
};

pub const FragmentDefinition = struct {
    name: []const u8,
    type_condition: NamedType,
    directives: std.array_list.Managed(Directive),
    selection_set: SelectionSet,
    line: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, type_condition: NamedType, line: usize, col: usize) FragmentDefinition {
        return .{
            .name = name,
            .type_condition = type_condition,
            .directives = std.array_list.Managed(Directive).init(allocator),
            .selection_set = SelectionSet.init(allocator),
            .line = line,
            .col = col,
        };
    }

    pub fn deinit(self: *FragmentDefinition, allocator: std.mem.Allocator) void {
        for (self.directives.items) |*d| d.deinit(allocator);
        self.directives.deinit();
        self.selection_set.deinit(allocator);
    }
};

pub const SelectionSet = struct {
    selections: std.array_list.Managed(Selection),

    pub fn init(allocator: std.mem.Allocator) SelectionSet {
        return .{ .selections = std.array_list.Managed(Selection).init(allocator) };
    }

    pub fn deinit(self: *SelectionSet, allocator: std.mem.Allocator) void {
        for (self.selections.items) |*sel| {
            sel.deinit(allocator);
        }
        self.selections.deinit();
    }
};

pub const Selection = union(enum) {
    field: Field,
    fragment_spread: FragmentSpread,
    inline_fragment: InlineFragment,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .field => |*f| f.deinit(allocator),
            .fragment_spread => |*fs| fs.deinit(allocator),
            .inline_fragment => |*ifrag| ifrag.deinit(allocator),
        }
    }
};

pub const Field = struct {
    alias: ?[]const u8 = null,
    name: []const u8,
    arguments: std.array_list.Managed(Argument),
    directives: std.array_list.Managed(Directive),
    selection_set: ?SelectionSet = null,
    line: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, line: usize, col: usize) Field {
        return .{
            .name = name,
            .arguments = std.array_list.Managed(Argument).init(allocator),
            .directives = std.array_list.Managed(Directive).init(allocator),
            .line = line,
            .col = col,
        };
    }

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        for (self.arguments.items) |*arg| arg.deinit(allocator);
        self.arguments.deinit();
        for (self.directives.items) |*d| d.deinit(allocator);
        self.directives.deinit();
        if (self.selection_set) |*ss| ss.deinit(allocator);
    }
};

pub const FragmentSpread = struct {
    name: []const u8,
    directives: std.array_list.Managed(Directive),
    line: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, line: usize, col: usize) FragmentSpread {
        return .{
            .name = name,
            .directives = std.array_list.Managed(Directive).init(allocator),
            .line = line,
            .col = col,
        };
    }

    pub fn deinit(self: *FragmentSpread, allocator: std.mem.Allocator) void {
        for (self.directives.items) |*d| d.deinit(allocator);
        self.directives.deinit();
    }
};

pub const InlineFragment = struct {
    type_condition: ?NamedType = null,
    directives: std.array_list.Managed(Directive),
    selection_set: SelectionSet,
    line: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, line: usize, col: usize) InlineFragment {
        return .{
            .directives = std.array_list.Managed(Directive).init(allocator),
            .selection_set = SelectionSet.init(allocator),
            .line = line,
            .col = col,
        };
    }

    pub fn deinit(self: *InlineFragment, allocator: std.mem.Allocator) void {
        for (self.directives.items) |*d| d.deinit(allocator);
        self.directives.deinit();
        self.selection_set.deinit(allocator);
    }
};

pub const Argument = struct {
    name: []const u8,
    value: AstValue,

    pub fn deinit(self: *Argument, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }
};

pub const Directive = struct {
    name: []const u8,
    arguments: std.array_list.Managed(Argument),
    line: usize = 0,
    col: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Directive {
        return .{
            .name = name,
            .arguments = std.array_list.Managed(Argument).init(allocator),
        };
    }

    pub fn deinit(self: *Directive, allocator: std.mem.Allocator) void {
        for (self.arguments.items) |*arg| arg.deinit(allocator);
        self.arguments.deinit();
    }
};

pub const VariableDefinition = struct {
    name: []const u8,
    var_type: Type,
    default_value: ?AstValue = null,
    directives: std.array_list.Managed(Directive),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, var_type: Type) VariableDefinition {
        return .{
            .name = name,
            .var_type = var_type,
            .directives = std.array_list.Managed(Directive).init(allocator),
        };
    }

    pub fn deinit(self: *VariableDefinition, allocator: std.mem.Allocator) void {
        self.var_type.deinit(allocator);
        if (self.default_value) |*dv| dv.deinit(allocator);
        for (self.directives.items) |*d| d.deinit(allocator);
        self.directives.deinit();
    }
};

pub const Type = union(enum) {
    named: NamedType,
    list: *Type,
    non_null: *Type,

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |ptr| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
            },
            .non_null => |ptr| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
            },
            .named => {},
        }
    }
};

pub const NamedType = struct {
    name: []const u8,
};

/// AST-level value (may contain variable references).
pub const AstValue = union(enum) {
    variable: []const u8,
    int_value: []const u8,
    float_value: []const u8,
    string_value: []const u8,
    boolean_value: bool,
    null_value: void,
    enum_value: []const u8,
    list_value: std.array_list.Managed(AstValue),
    object_value: std.StringHashMap(AstValue),

    pub fn deinit(self: *AstValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string_value => |s| allocator.free(s),
            .list_value => |*list| {
                for (list.items) |*item| item.deinit(allocator);
                list.deinit();
            },
            .object_value => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }
};

test "ast basic" {
    const allocator = std.testing.allocator;
    var doc = Document.init(allocator);
    defer doc.deinit();

    const op = OperationDefinition.init(allocator, .query, 1, 1);
    try doc.definitions.append(.{ .operation = op });
}
