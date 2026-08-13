const std = @import("std");
const Value = @import("value.zig").Value;
const ast = @import("ast.zig");

/// Schema type system.
pub const DirectiveLocation = enum {
    query,
    mutation,
    subscription,
    field,
    fragment_definition,
    fragment_spread,
    inline_fragment,
    variable_definition,
    schema,
    scalar,
    object,
    field_definition,
    argument_definition,
    interface,
    union_type,
    enum_type,
    enum_value,
    input_object,
    input_field_definition,
};

pub const DirectiveDefinition = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    locations: std.array_list.Managed(DirectiveLocation),
    arguments: std.StringHashMap(InputValue),
    is_repeatable: bool = false,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) DirectiveDefinition {
        return .{
            .name = name,
            .locations = std.array_list.Managed(DirectiveLocation).init(allocator),
            .arguments = std.StringHashMap(InputValue).init(allocator),
        };
    }

    pub fn deinit(self: *DirectiveDefinition, allocator: std.mem.Allocator) void {
        self.locations.deinit();
        if (self.description) |d| allocator.free(d);
        var aiter = self.arguments.iterator();
        while (aiter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.arguments.deinit();
    }
};

pub const Schema = struct {
    allocator: std.mem.Allocator,
    query_type: *Type,
    mutation_type: ?*Type = null,
    subscription_type: ?*Type = null,
    description: ?[]const u8 = null,
    types: std.StringHashMap(*Type),
    directives: std.StringHashMap(DirectiveDefinition),

    pub fn init(allocator: std.mem.Allocator, query_type: *Type) !Schema {
        var s = Schema{
            .allocator = allocator,
            .query_type = query_type,
            .types = std.StringHashMap(*Type).init(allocator),
            .directives = std.StringHashMap(DirectiveDefinition).init(allocator),
        };
        errdefer {
            var diter = s.directives.iterator();
            while (diter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            s.directives.deinit();
        }
        try s.registerBuiltinDirectives(allocator);
        return s;
    }

    pub fn deinit(self: *Schema) void {
        if (self.description) |d| self.allocator.free(d);
        var iter = self.types.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.types.deinit();

        var diter = self.directives.iterator();
        while (diter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.directives.deinit();
    }

    pub fn registerType(self: *Schema, name: []const u8, typ: *Type) !void {
        try self.types.put(name, typ);
    }

    pub fn getType(self: *Schema, name: []const u8) ?*Type {
        return self.types.get(name);
    }

    pub fn registerDirective(self: *Schema, name: []const u8, def: DirectiveDefinition) !void {
        try self.directives.put(name, def);
    }

    pub fn getDirective(self: *Schema, name: []const u8) ?*DirectiveDefinition {
        return self.directives.getPtr(name);
    }

    fn registerBuiltinDirectives(self: *Schema, allocator: std.mem.Allocator) !void {
        // @skip(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
        {
            var skip = DirectiveDefinition.init(allocator, "skip");
            var skip_owned = true;
            defer if (skip_owned) skip.deinit(allocator);
            try skip.locations.append(.field);
            try skip.locations.append(.fragment_spread);
            try skip.locations.append(.inline_fragment);
            const skip_bool = try allocator.create(TypeRef);
            var skip_bool_owned = true;
            defer if (skip_bool_owned) allocator.destroy(skip_bool);
            skip_bool.* = TypeRef.named("Boolean");
            const skip_if = InputValue{ .name = "if", .value_type = TypeRef.nonNull(skip_bool) };
            const skip_if_key = try allocator.dupe(u8, "if");
            var skip_if_key_owned = true;
            defer if (skip_if_key_owned) allocator.free(skip_if_key);
            try skip.arguments.put(skip_if_key, skip_if);
            skip_if_key_owned = false;
            skip_bool_owned = false; // now owned by skip (via skip_if.value_type)
            const skip_key = try allocator.dupe(u8, "skip");
            var skip_key_owned = true;
            defer if (skip_key_owned) allocator.free(skip_key);
            try self.directives.put(skip_key, skip);
            skip_key_owned = false;
            skip_owned = false; // now owned by self.directives
        }

        // @include(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
        {
            var include = DirectiveDefinition.init(allocator, "include");
            var include_owned = true;
            defer if (include_owned) include.deinit(allocator);
            try include.locations.append(.field);
            try include.locations.append(.fragment_spread);
            try include.locations.append(.inline_fragment);
            const include_bool = try allocator.create(TypeRef);
            var include_bool_owned = true;
            defer if (include_bool_owned) allocator.destroy(include_bool);
            include_bool.* = TypeRef.named("Boolean");
            const include_if = InputValue{ .name = "if", .value_type = TypeRef.nonNull(include_bool) };
            const include_if_key = try allocator.dupe(u8, "if");
            var include_if_key_owned = true;
            defer if (include_if_key_owned) allocator.free(include_if_key);
            try include.arguments.put(include_if_key, include_if);
            include_if_key_owned = false;
            include_bool_owned = false; // now owned by include (via include_if.value_type)
            const include_key = try allocator.dupe(u8, "include");
            var include_key_owned = true;
            defer if (include_key_owned) allocator.free(include_key);
            try self.directives.put(include_key, include);
            include_key_owned = false;
            include_owned = false; // now owned by self.directives
        }
    }
};

pub const Type = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    kind: Kind,

    pub const Kind = union(enum) {
        scalar: ScalarType,
        object: ObjectType,
        interface: InterfaceType,
        union_type: UnionType,
        enum_type: EnumType,
        input_object: InputObjectType,
    };

    pub fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        if (self.description) |d| allocator.free(d);
        switch (self.kind) {
            .object => |*obj| obj.deinit(allocator),
            .interface => |*iface| iface.deinit(allocator),
            .union_type => |*u| u.deinit(allocator),
            .enum_type => |*e| e.deinit(allocator),
            .input_object => |*io| io.deinit(allocator),
            .scalar => {},
        }
    }

    pub fn isScalar(self: Type) bool {
        return self.kind == .scalar;
    }

    pub fn isObject(self: Type) bool {
        return self.kind == .object;
    }

    pub fn isInterface(self: Type) bool {
        return self.kind == .interface;
    }

    pub fn isUnion(self: Type) bool {
        return self.kind == .union_type;
    }

    pub fn isEnum(self: Type) bool {
        return self.kind == .enum_type;
    }

    pub fn isInputObject(self: Type) bool {
        return self.kind == .input_object;
    }

    pub fn isInputType(self: Type) bool {
        return self.isScalar() or self.isEnum() or self.isInputObject();
    }

    pub fn isComposite(self: Type) bool {
        return self.isObject() or self.isInterface() or self.isUnion();
    }

    pub fn isAbstract(self: Type) bool {
        return self.isInterface() or self.isUnion();
    }

    pub fn getField(self: *Type, name: []const u8) ?*Field {
        switch (self.kind) {
            .object => |*obj| return obj.fields.getPtr(name),
            .interface => |*iface| return iface.fields.getPtr(name),
            else => return null,
        }
    }
};

pub const ScalarType = struct {
    /// Optional custom coerce function.
    coerce: ?*const fn (allocator: std.mem.Allocator, value: ast.AstValue) anyerror!Value = null,
};

pub const ObjectType = struct {
    fields: std.StringHashMap(Field),
    interfaces: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) ObjectType {
        return .{
            .fields = std.StringHashMap(Field).init(allocator),
            .interfaces = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ObjectType, allocator: std.mem.Allocator) void {
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.fields.deinit();
        self.interfaces.deinit();
    }
};

pub const InterfaceType = struct {
    fields: std.StringHashMap(Field),
    possible_types: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) InterfaceType {
        return .{
            .fields = std.StringHashMap(Field).init(allocator),
            .possible_types = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *InterfaceType, allocator: std.mem.Allocator) void {
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.fields.deinit();
        self.possible_types.deinit();
    }
};

pub const UnionType = struct {
    possible_types: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) UnionType {
        return .{ .possible_types = std.array_list.Managed([]const u8).init(allocator) };
    }

    pub fn deinit(self: *UnionType, _: std.mem.Allocator) void {
        self.possible_types.deinit();
    }
};

pub const EnumType = struct {
    values: std.StringHashMap(EnumValue),

    pub fn init(allocator: std.mem.Allocator) EnumType {
        return .{ .values = std.StringHashMap(EnumValue).init(allocator) };
    }

    pub fn deinit(self: *EnumType, allocator: std.mem.Allocator) void {
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.description) |d| allocator.free(d);
        }
        self.values.deinit();
    }
};

pub const EnumValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const InputObjectType = struct {
    fields: std.StringHashMap(InputValue),

    pub fn init(allocator: std.mem.Allocator) InputObjectType {
        return .{ .fields = std.StringHashMap(InputValue).init(allocator) };
    }

    pub fn deinit(self: *InputObjectType, allocator: std.mem.Allocator) void {
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.fields.deinit();
    }
};

/// A stream of values produced by a GraphQL subscription resolver.
/// The consumer repeatedly calls `next()` to receive new events.
/// Each yielded Value is a raw payload (not yet wrapped in a GraphQL response).
pub const SubscriptionStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Block until the next event is available, or return null if the stream has ended.
        /// The returned Value should be treated as a "parent" value for the subscription field.
        /// The returned Value must be allocated with `allocator`.
        next: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?Value,
        /// Clean up the stream and any associated resources.
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        /// Optional: signal the stream to stop producing events.
        /// After cancel is called, subsequent `next()` calls should return null promptly.
        cancel: ?*const fn (ptr: *anyopaque) void = null,
    };

    /// Returns the next event Value, allocated with `allocator`. For streams
    /// produced by `Executor.executeSubscription`, `allocator` MUST be the
    /// same allocator the Executor was created with (the executor builds
    /// sub-selection results with its own allocator).
    pub fn next(self: SubscriptionStream, allocator: std.mem.Allocator) !?Value {
        return self.vtable.next(self.ptr, allocator);
    }

    pub fn deinit(self: SubscriptionStream, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    pub fn cancel(self: SubscriptionStream) void {
        if (self.vtable.cancel) |cb| cb(self.ptr);
    }
};

pub const Field = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    field_type: TypeRef,
    arguments: std.StringHashMap(InputValue),
    deprecation_reason: ?[]const u8 = null,
    /// If set, the field requires the current user to have this role.
    required_role: ?[]const u8 = null,
    // Resolver is set at runtime by the application.
    // The allocator should be used for all allocations in the returned Value.
    resolve: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, parent: Value, args: std.StringHashMap(Value)) anyerror!Value = null,
    /// Optional subscription source. When set, the field can be used as a subscription root.
    /// The returned SubscriptionStream yields parent values that are then passed through
    /// the field's selection set to produce each event payload.
    subscribe: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, parent: Value, args: std.StringHashMap(Value)) anyerror!SubscriptionStream = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, field_type: TypeRef) Field {
        return .{
            .name = name,
            .field_type = field_type,
            .arguments = std.StringHashMap(InputValue).init(allocator),
        };
    }

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        self.field_type.deinit(allocator);
        if (self.description) |d| allocator.free(d);
        if (self.deprecation_reason) |r| allocator.free(r);
        var iter = self.arguments.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.arguments.deinit();
    }
};

pub const InputValue = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    value_type: TypeRef,
    default_value: ?Value = null,
    deprecation_reason: ?[]const u8 = null,

    pub fn deinit(self: *InputValue, allocator: std.mem.Allocator) void {
        self.value_type.deinit(allocator);
        if (self.description) |d| allocator.free(d);
        if (self.default_value) |*dv| dv.deinit(allocator);
    }
};

/// Type reference: may be wrapped in List or NonNull.
pub const TypeRef = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        named: []const u8,
        list: *TypeRef,
        non_null: *TypeRef,
    };

    pub fn named(name: []const u8) TypeRef {
        return .{ .kind = .{ .named = name } };
    }

    pub fn list(inner: *TypeRef) TypeRef {
        return .{ .kind = .{ .list = inner } };
    }

    pub fn nonNull(inner: *TypeRef) TypeRef {
        return .{ .kind = .{ .non_null = inner } };
    }

    pub fn deinit(self: *TypeRef, allocator: std.mem.Allocator) void {
        switch (self.kind) {
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

    pub fn isNonNull(self: TypeRef) bool {
        return self.kind == .non_null;
    }

    pub fn isList(self: TypeRef) bool {
        return self.kind == .list;
    }

    pub fn innerTypeName(self: TypeRef) []const u8 {
        switch (self.kind) {
            .named => |n| return n,
            .list => |ptr| return ptr.innerTypeName(),
            .non_null => |ptr| return ptr.innerTypeName(),
        }
    }
};

/// Built-in scalar types.
pub const string_scalar = Type{ .name = "String", .kind = .{ .scalar = .{} } };
pub const int_scalar = Type{ .name = "Int", .kind = .{ .scalar = .{} } };
pub const float_scalar = Type{ .name = "Float", .kind = .{ .scalar = .{} } };
pub const boolean_scalar = Type{ .name = "Boolean", .kind = .{ .scalar = .{} } };
pub const id_scalar = Type{ .name = "ID", .kind = .{ .scalar = .{} } };

test "schema basic" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = ObjectType.init(allocator) },
    };

    const user_type = try allocator.create(Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = ObjectType.init(allocator) },
    };

    var schema = try Schema.init(allocator, query_type);
    defer schema.deinit();

    try schema.registerType("Query", query_type);
    try schema.registerType("User", user_type);
    try std.testing.expect(schema.getType("User") != null);
}

test "type ref" {
    const allocator = std.testing.allocator;
    var ref = TypeRef.named("String");
    try std.testing.expectEqualStrings("String", ref.innerTypeName());
    ref.deinit(allocator);
}
