const std = @import("std");
const schema = @import("schema.zig");
const Value = @import("value.zig").Value;
const SchemaBuilder = @import("schema_builder.zig").SchemaBuilder;

/// Compile-time type-safe schema builder that binds resolvers directly into the DSL.
///
/// `Context` is the user-defined type passed to every resolver as `ctx`.
/// Use `void` if no context is needed.
///
/// Resolver functions should have one of these signatures:
///   fn(ctx: *Context, allocator: std.mem.Allocator) anyerror!ReturnType
///   fn(ctx: *Context, allocator: std.mem.Allocator, args: ArgsStruct) anyerror!ReturnType
///
/// Subscribe resolvers:
///   fn(ctx: *Context, allocator: std.mem.Allocator) anyerror!schema.SubscriptionStream
///   fn(ctx: *Context, allocator: std.mem.Allocator, args: ArgsStruct) anyerror!schema.SubscriptionStream
pub fn TypeSafeSchemaBuilder(comptime Context: type, comptime def: anytype) type {
    const ThunkEntry = struct {
        type_name: []const u8,
        field_name: []const u8,
        kind: enum { resolve, subscribe },
        ptr: *const anyopaque,
    };

    // Pre-generate all thunks at compile time.
    const thunk_entries = comptime blk: {
        var count: usize = 0;
        for (@typeInfo(@TypeOf(def)).@"struct".field_names) |type_name| {
            const type_value = @field(def, type_name);
            for (@typeInfo(@TypeOf(type_value)).@"struct".field_names) |field_name| {
                const field_value = @field(type_value, field_name);
                if (@hasField(@TypeOf(field_value), "resolve")) count += 1;
                if (@hasField(@TypeOf(field_value), "subscribe")) count += 1;
            }
        }

        var entries: [count]ThunkEntry = undefined;
        var idx: usize = 0;
        for (@typeInfo(@TypeOf(def)).@"struct".field_names) |type_name| {
            const type_value = @field(def, type_name);
            for (@typeInfo(@TypeOf(type_value)).@"struct".field_names) |field_name| {
                const field_value = @field(type_value, field_name);
                if (@hasField(@TypeOf(field_value), "resolve")) {
                    const resolver_fn = @field(field_value, "resolve");
                    const thunk = makeResolveThunk(Context, resolver_fn);
                    entries[idx] = .{
                        .type_name = type_name,
                        .field_name = field_name,
                        .kind = .resolve,
                        .ptr = thunk,
                    };
                    idx += 1;
                }
                if (@hasField(@TypeOf(field_value), "subscribe")) {
                    const subscribe_fn = @field(field_value, "subscribe");
                    const thunk = makeSubscribeThunk(Context, subscribe_fn);
                    entries[idx] = .{
                        .type_name = type_name,
                        .field_name = field_name,
                        .kind = .subscribe,
                        .ptr = thunk,
                    };
                    idx += 1;
                }
            }
        }
        break :blk entries;
    };

    return struct {
        pub const sdl: []const u8 = SchemaBuilder(def).sdl;

        pub fn init(allocator: std.mem.Allocator) !schema.Schema {
            var s = try SchemaBuilder(def).init(allocator);
            errdefer s.deinit();

            for (thunk_entries) |entry| {
                const schema_type = s.getType(entry.type_name) orelse continue;
                if (schema_type.kind != .object) continue;
                if (schema_type.kind.object.fields.getPtr(entry.field_name)) |field_ptr| {
                    switch (entry.kind) {
                        .resolve => field_ptr.resolve = @ptrCast(@alignCast(entry.ptr)),
                        .subscribe => field_ptr.subscribe = @ptrCast(@alignCast(entry.ptr)),
                    }
                }
            }

            return s;
        }
    };
}

fn makeResolveThunk(comptime Context: type, comptime resolver: anytype) *const fn (?*anyopaque, std.mem.Allocator, Value, std.StringHashMap(Value)) anyerror!Value {
    return struct {
        fn thunk(ctx: ?*anyopaque, allocator: std.mem.Allocator, parent: Value, raw_args: std.StringHashMap(Value)) anyerror!Value {
            _ = parent;
            const typed_ctx = if (Context == void) {} else @as(*Context, @ptrCast(@alignCast(ctx)));

            const ResolveInfo = @typeInfo(@TypeOf(resolver)).@"fn";
            const has_args = ResolveInfo.param_types.len == 3;

            if (has_args) {
                const AT = ResolveInfo.param_types[2].?;
                if (AT != void) {
                    const args = try coerceArgs(allocator, raw_args, AT);
                    defer deinitArgs(allocator, args);
                    const result = try resolver(typed_ctx, allocator, args);
                    return try serializeValue(allocator, result);
                }
            }

            const result = try resolver(typed_ctx, allocator);
            return try serializeValue(allocator, result);
        }
    }.thunk;
}

fn makeSubscribeThunk(comptime Context: type, comptime resolver: anytype) *const fn (?*anyopaque, std.mem.Allocator, Value, std.StringHashMap(Value)) anyerror!schema.SubscriptionStream {
    return struct {
        fn thunk(ctx: ?*anyopaque, allocator: std.mem.Allocator, parent: Value, raw_args: std.StringHashMap(Value)) anyerror!schema.SubscriptionStream {
            _ = parent;
            const typed_ctx = if (Context == void) {} else @as(*Context, @ptrCast(@alignCast(ctx)));

            const ResolveInfo = @typeInfo(@TypeOf(resolver)).@"fn";
            const has_args = ResolveInfo.param_types.len == 3;

            if (has_args) {
                const AT = ResolveInfo.param_types[2].?;
                if (AT != void) {
                    const args = try coerceArgs(allocator, raw_args, AT);
                    defer deinitArgs(allocator, args);
                    return try resolver(typed_ctx, allocator, args);
                }
            }

            return try resolver(typed_ctx, allocator);
        }
    }.thunk;
}

fn coerceArgs(allocator: std.mem.Allocator, raw: std.StringHashMap(Value), comptime Args: type) !Args {
    var result: Args = undefined;
    inline for (@typeInfo(Args).@"struct".field_names, @typeInfo(Args).@"struct".field_types) |key, FieldType| {
        const val = raw.get(key) orelse return error.ResolverError;
        @field(result, key) = try coerceValue(allocator, val, FieldType);
    }
    return result;
}

fn deinitArgs(allocator: std.mem.Allocator, args: anytype) void {
    const T = @TypeOf(args);
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| {
        deinitValue(allocator, @field(args, name), FieldType);
    }
}

fn deinitValue(allocator: std.mem.Allocator, val: anytype, comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                allocator.free(val);
            }
        },
        .optional => |o| {
            if (val != null) deinitValue(allocator, val.?, o.child);
        },
        .array, .vector => {
            for (val) |item| {
                deinitValue(allocator, item, @TypeOf(item));
            }
        },
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| {
                deinitValue(allocator, @field(val, name), FieldType);
            }
        },
        else => {},
    }
}

fn coerceValue(allocator: std.mem.Allocator, val: Value, comptime T: type) !T {
    switch (@typeInfo(T)) {
        .int => return @intCast(val.data.int),
        .float => return @floatCast(val.data.float),
        .bool => return val.data.boolean,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                return try allocator.dupe(u8, val.data.string);
            }
            @compileError("Unsupported pointer coercion: " ++ @typeName(T));
        },
        .optional => |o| {
            if (val.data == .null) return null;
            return try coerceValue(allocator, val, o.child);
        },
        .array => |a| {
            if (val.data != .list) return error.ResolverError;
            if (val.data.list.items.len != a.len) return error.ResolverError;
            var result: T = undefined;
            for (val.data.list.items, 0..) |item, i| {
                result[i] = try coerceValue(allocator, item, a.child);
            }
            return result;
        },
        .@"struct" => {
            if (val.data != .object) return error.ResolverError;
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, FieldType| {
                const field_val = val.data.object.get(name) orelse return error.ResolverError;
                @field(result, name) = try coerceValue(allocator, field_val, FieldType);
            }
            return result;
        },
        else => @compileError("Unsupported coercion type: " ++ @typeName(T)),
    }
}

fn serializeValue(allocator: std.mem.Allocator, val: anytype) !Value {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .int => return Value.fromInt(allocator, val),
        .float => return Value.fromFloat(allocator, val),
        .bool => return Value.fromBool(allocator, val),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                return Value.fromString(allocator, val);
            }
            @compileError("Unsupported pointer serialization: " ++ @typeName(T));
        },
        .optional => {
            if (val == null) return Value.fromNull(allocator);
            return try serializeValue(allocator, val.?);
        },
        .array => {
            var list = Value.initList(allocator);
            errdefer list.deinit();
            for (val) |item| {
                try list.data.list.append(try serializeValue(allocator, item));
            }
            return list;
        },
        .@"struct" => {
            var obj = Value.initObject(allocator);
            errdefer obj.deinit(allocator);
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                const field_val = try serializeValue(allocator, @field(val, name));
                try obj.data.object.put(try allocator.dupe(u8, name), field_val);
            }
            return obj;
        },
        else => @compileError("Unsupported serialization type: " ++ @typeName(T)),
    }
}


test "TypeSafeSchemaBuilder basic resolver" {
    const allocator = std.testing.allocator;

    const MyContext = struct {
        greeting: []const u8,
    };

    const Builder = TypeSafeSchemaBuilder(MyContext, .{
        .Query = .{
            .hello = .{
                .type = "String!",
                .resolve = struct {
                    fn resolve(ctx: *MyContext, alloc: std.mem.Allocator) anyerror![]const u8 {
                        return try alloc.dupe(u8, ctx.greeting);
                    }
                }.resolve,
            },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    try std.testing.expectEqualStrings("Query", schema_def.query_type.name);

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = @import("executor.zig").Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var parser = @import("parser.zig").Parser.init(allocator, "{ hello }") catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var ctx = MyContext{ .greeting = "world" };
    executor.context.user_data = &ctx;

    var result = try executor.execute(&doc);
    defer result.deinit(allocator);

    try std.testing.expect(result.data == .object);
    const data = result.data.object.get("data") orelse return error.TestUnexpectedResult;
    try std.testing.expect(data.data == .object);
    const hello = data.data.object.get("hello") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hello.data == .string);
    try std.testing.expectEqualStrings("world", hello.data.string);
}

test "TypeSafeSchemaBuilder resolver with args" {
    const allocator = std.testing.allocator;

    const Args = struct {
        multiplier: i64,
    };

    const Builder = TypeSafeSchemaBuilder(void, .{
        .Query = .{
            .double = .{
                .type = "Int!",
                .args = .{ .multiplier = .{ .type = "Int!" } },
                .resolve = struct {
                    fn resolve(_: void, _: std.mem.Allocator, args: Args) anyerror!i64 {
                        return args.multiplier * 2;
                    }
                }.resolve,
            },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = @import("executor.zig").Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var parser = @import("parser.zig").Parser.init(allocator, "{ double(multiplier: 7) }") catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit(allocator);

    try std.testing.expect(result.data == .object);
    const data = result.data.object.get("data") orelse return error.TestUnexpectedResult;
    const double = data.data.object.get("double") orelse return error.TestUnexpectedResult;
    try std.testing.expect(double.data == .int);
    try std.testing.expectEqual(14, double.data.int);
}

test "TypeSafeSchemaBuilder resolver returning struct" {
    const allocator = std.testing.allocator;

    const User = struct {
        name: []const u8,
        age: i64,
    };

    const Builder = TypeSafeSchemaBuilder(void, .{
        .Query = .{
            .user = .{
                .type = "User!",
                .resolve = struct {
                    fn resolve(_: void, alloc: std.mem.Allocator) anyerror!User {
                        return User{
                            .name = try alloc.dupe(u8, "Alice"),
                            .age = 30,
                        };
                    }
                }.resolve,
            },
        },
        .User = .{
            .name = .{ .type = "String!" },
            .age = .{ .type = "Int!" },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = @import("executor.zig").Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var parser = @import("parser.zig").Parser.init(allocator, "{ user { name age } }") catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit(allocator);

    try std.testing.expect(result.data == .object);
    const data = result.data.object.get("data") orelse return error.TestUnexpectedResult;
    const user = data.data.object.get("user") orelse return error.TestUnexpectedResult;
    try std.testing.expect(user.data == .object);
    const name = user.data.object.get("name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Alice", name.data.string);
    const age = user.data.object.get("age") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(30, age.data.int);
}
