const std = @import("std");

/// Managed ArrayList alias for convenience.
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// GraphQL Value representation.
/// Maps directly to the GraphQL specification's value types.
///
/// A `Value` does not own an allocator; release and cloning methods take an
/// explicit allocator argument. This matches the Zig convention and allows a
/// value to be moved across allocator boundaries (e.g. into an arena).
pub const Value = struct {
    data: Data,

    pub const Data = union(enum) {
        null: void,
        int: i64,
        float: f64,
        string: []const u8,
        boolean: bool,
        enum_value: []const u8,
        list: ArrayList(Value),
        object: std.StringHashMap(Value),
    };

    /// The allocator argument is accepted for API consistency but not stored;
    /// primitive values carry no owned memory.
    pub fn fromNull(allocator: std.mem.Allocator) Value {
        _ = allocator;
        return .{ .data = .{ .null = {} } };
    }

    pub fn fromInt(allocator: std.mem.Allocator, v: i64) Value {
        _ = allocator;
        return .{ .data = .{ .int = v } };
    }

    pub fn fromFloat(allocator: std.mem.Allocator, v: f64) Value {
        _ = allocator;
        return .{ .data = .{ .float = v } };
    }

    /// Takes ownership of the string slice.
    pub fn fromString(allocator: std.mem.Allocator, v: []const u8) Value {
        _ = allocator;
        return .{ .data = .{ .string = v } };
    }

    pub fn fromBool(allocator: std.mem.Allocator, v: bool) Value {
        _ = allocator;
        return .{ .data = .{ .boolean = v } };
    }

    /// Takes ownership of the string slice.
    pub fn fromEnum(allocator: std.mem.Allocator, v: []const u8) Value {
        _ = allocator;
        return .{ .data = .{ .enum_value = v } };
    }

    pub fn initList(allocator: std.mem.Allocator) Value {
        return .{ .data = .{ .list = ArrayList(Value).init(allocator) } };
    }

    pub fn initObject(allocator: std.mem.Allocator) Value {
        return .{ .data = .{ .object = std.StringHashMap(Value).init(allocator) } };
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .string => |v| allocator.free(v),
            .enum_value => |v| allocator.free(v),
            .list => |*list| {
                for (list.items) |*item| {
                    item.deinit(allocator);
                }
                list.deinit();
            },
            .object => |*obj| {
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

    /// Deep clone a value into a caller-chosen allocator.
    pub fn clone(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        switch (self.data) {
            .null => return fromNull(allocator),
            .int => |v| return fromInt(allocator, v),
            .float => |v| return fromFloat(allocator, v),
            .string => |v| return fromString(allocator, try allocator.dupe(u8, v)),
            .boolean => |v| return fromBool(allocator, v),
            .enum_value => |v| return fromEnum(allocator, try allocator.dupe(u8, v)),
            .list => |list| {
                var new = initList(allocator);
                errdefer new.deinit(allocator);
                for (list.items) |item| {
                    try new.data.list.append(try item.clone(allocator));
                }
                return new;
            },
            .object => |obj| {
                var new = initObject(allocator);
                errdefer new.deinit(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    try new.data.object.put(key, try entry.value_ptr.clone(allocator));
                }
                return new;
            },
        }
    }

    pub const JsonError = std.mem.Allocator.Error || std.Io.Writer.Error;

    /// Serialize to JSON. Caller owns the returned string.
    pub fn toJson(self: Value, allocator: std.mem.Allocator) JsonError![]const u8 {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        try self.writeJson(&allocating.writer, allocator);
        var arr = allocating.toArrayList();
        return arr.toOwnedSlice(allocator);
    }

    pub fn writeJson(self: Value, writer: *std.Io.Writer, allocator: std.mem.Allocator) JsonError!void {
        switch (self.data) {
            .null => try writer.writeAll("null"),
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| {
                if (std.math.isNan(v)) {
                    try writer.writeAll("null");
                } else if (std.math.isInf(v)) {
                    try writer.writeAll("null");
                } else {
                    try writer.print("{d}", .{v});
                }
            },
            .string => |v| try writeJsonString(v, writer),
            .boolean => |v| try writer.writeAll(if (v) "true" else "false"),
            .enum_value => |v| try writeJsonString(v, writer),
            .list => |list| {
                try writer.writeByte('[');
                for (list.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try item.writeJson(writer, allocator);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                // Sort keys for deterministic output
                var sorted = ArrayList([]const u8).init(allocator);
                defer sorted.deinit();
                var key_iter = obj.keyIterator();
                while (key_iter.next()) |key| {
                    sorted.append(key.*) catch |err| return @errorCast(err);
                }
                std.mem.sort([]const u8, sorted.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lessThan);
                for (sorted.items, 0..) |key, i| {
                    if (i > 0) try writer.writeByte(',');
                    try writeJsonString(key, writer);
                    try writer.writeByte(':');
                    try obj.get(key).?.writeJson(writer, allocator);
                }
                try writer.writeByte('}');
            },
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        if (std.meta.activeTag(self.data) != std.meta.activeTag(other.data)) return false;
        switch (self.data) {
            .null => return true,
            .int => |a| return a == other.data.int,
            .float => |a| return a == other.data.float,
            .string => |a| return std.mem.eql(u8, a, other.data.string),
            .boolean => |a| return a == other.data.boolean,
            .enum_value => |a| return std.mem.eql(u8, a, other.data.enum_value),
            .list => |a| {
                if (a.items.len != other.data.list.items.len) return false;
                for (a.items, other.data.list.items) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
            .object => return false, // Deep object comparison omitted for simplicity
        }
    }

    /// Parse a JSON string into a GraphQL Value tree.
    /// Caller owns the returned Value and must call deinit().
    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) (std.mem.Allocator.Error || error{InvalidJson})!Value {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        return try fromStdJson(allocator, parsed.value);
    }

    /// Convert std.json.Value to GraphQL Value recursively.
    fn fromStdJson(allocator: std.mem.Allocator, json_val: std.json.Value) std.mem.Allocator.Error!Value {
        switch (json_val) {
            .null => return fromNull(allocator),
            .bool => |b| return fromBool(allocator, b),
            .integer => |i| return fromInt(allocator, i),
            .float => |f| return fromFloat(allocator, f),
            .number_string => |s| {
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    return fromInt(allocator, i);
                } else |_| {
                    if (std.fmt.parseFloat(f64, s)) |f| {
                        return fromFloat(allocator, f);
                    } else |_| {
                        return fromString(allocator, try allocator.dupe(u8, s));
                    }
                }
            },
            .string => |s| return fromString(allocator, try allocator.dupe(u8, s)),
            .array => |arr| {
                var list = initList(allocator);
                errdefer list.deinit(allocator);
                for (arr.items) |item| {
                    try list.data.list.append(try fromStdJson(allocator, item));
                }
                return list;
            },
            .object => |obj| {
                var graph_obj = initObject(allocator);
                errdefer graph_obj.deinit(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try graph_obj.data.object.put(try allocator.dupe(u8, entry.key_ptr.*), try fromStdJson(allocator, entry.value_ptr.*));
                }
                return graph_obj;
            },
        }
    }
};

fn writeJsonString(str: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        const c = str[i];
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "value basic types" {
    const allocator = std.testing.allocator;
    const v1 = Value.fromInt(allocator, 42);
    try std.testing.expectEqual(@as(i64, 42), v1.data.int);

    const v2 = Value.fromString(allocator, "hello");
    try std.testing.expectEqualStrings("hello", v2.data.string);

    const v3 = Value.fromBool(allocator, true);
    try std.testing.expect(v3.data.boolean);
}

test "value json serialization" {
    const allocator = std.testing.allocator;

    // Null
    var null_val = Value.fromNull(allocator);
    const null_json = try null_val.toJson(allocator);
    defer allocator.free(null_json);
    try std.testing.expectEqualStrings("null", null_json);
    null_val.deinit(allocator);

    // Int
    var int_val = Value.fromInt(allocator, 42);
    const int_json = try int_val.toJson(allocator);
    defer allocator.free(int_json);
    try std.testing.expectEqualStrings("42", int_json);
    int_val.deinit(allocator);

    // String with escaping
    const str_dup = try allocator.dupe(u8, "hello\nworld\"\\");
    var str_val = Value.fromString(allocator, str_dup);
    const str_json = try str_val.toJson(allocator);
    defer allocator.free(str_json);
    try std.testing.expectEqualStrings("\"hello\\nworld\\\"\\\\\"", str_json);
    str_val.deinit(allocator);

    // List
    var list = Value.initList(allocator);
    try list.data.list.append(Value.fromInt(allocator, 1));
    try list.data.list.append(Value.fromString(allocator, try allocator.dupe(u8, "two")));
    const list_json = try list.toJson(allocator);
    defer allocator.free(list_json);
    try std.testing.expectEqualStrings("[1,\"two\"]", list_json);
    list.deinit(allocator);

    // Object
    var obj = Value.initObject(allocator);
    try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, "Alice")));
    try obj.data.object.put(try allocator.dupe(u8, "age"), Value.fromInt(allocator, 30));
    const obj_json = try obj.toJson(allocator);
    defer allocator.free(obj_json);
    try std.testing.expectEqualStrings("{\"age\":30,\"name\":\"Alice\"}", obj_json);
    obj.deinit(allocator);
}

test "value clone" {
    const allocator = std.testing.allocator;
    var original = Value.initObject(allocator);
    try original.data.object.put(try allocator.dupe(u8, "nested"), Value.initList(allocator));
    var nested_list = original.data.object.getPtr("nested").?;
    try nested_list.data.list.append(Value.fromString(allocator, try allocator.dupe(u8, "deep")));

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    defer original.deinit(allocator);

    try std.testing.expect(original.data.object.get("nested").?.data.list.items[0].data.string.ptr !=
        cloned.data.object.get("nested").?.data.list.items[0].data.string.ptr);
    try std.testing.expectEqualStrings("deep", cloned.data.object.get("nested").?.data.list.items[0].data.string);
}

test "value fromJson roundtrip" {
    const allocator = std.testing.allocator;

    // Primitives
    var null_val = try Value.fromJson(allocator, "null");
    defer null_val.deinit(allocator);
    try std.testing.expect(null_val.data == .null);

    var int_val = try Value.fromJson(allocator, "42");
    defer int_val.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), int_val.data.int);

    var float_val = try Value.fromJson(allocator, "3.14");
    defer float_val.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 3.14), float_val.data.float);

    var str_val = try Value.fromJson(allocator, "\"hello\"");
    defer str_val.deinit(allocator);
    try std.testing.expectEqualStrings("hello", str_val.data.string);

    var bool_val = try Value.fromJson(allocator, "true");
    defer bool_val.deinit(allocator);
    try std.testing.expect(bool_val.data.boolean);

    // Array
    var arr_val = try Value.fromJson(allocator, "[1, 2, 3]");
    defer arr_val.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), arr_val.data.list.items.len);
    try std.testing.expectEqual(@as(i64, 1), arr_val.data.list.items[0].data.int);

    // Object
    var obj_val = try Value.fromJson(allocator, "{\"name\":\"Alice\",\"age\":30}");
    defer obj_val.deinit(allocator);
    try std.testing.expectEqualStrings("Alice", obj_val.data.object.get("name").?.data.string);
    try std.testing.expectEqual(@as(i64, 30), obj_val.data.object.get("age").?.data.int);

    // Roundtrip: Value → JSON → Value → JSON
    var original = Value.initObject(allocator);
    try original.data.object.put(try allocator.dupe(u8, "x"), Value.fromInt(allocator, 1));
    const json = try original.toJson(allocator);
    defer allocator.free(json);
    var roundtripped = try Value.fromJson(allocator, json);
    defer roundtripped.deinit(allocator);
    defer original.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), roundtripped.data.object.get("x").?.data.int);
}

test "value fromJson invalid" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, Value.fromJson(allocator, "not json"));
}

test "value cloneWith crosses allocator boundary" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var original = Value.initObject(allocator);
    defer original.deinit(allocator);
    try original.data.object.put(try allocator.dupe(u8, "nested"), Value.initList(allocator));
    var nested_list = original.data.object.getPtr("nested").?;
    try nested_list.data.list.append(Value.fromString(allocator, try allocator.dupe(u8, "deep")));

    // Clone into the arena: the clone must be owned by the arena allocator.
    var cloned = try original.clone(arena_alloc);
    defer cloned.deinit(arena_alloc);

    try std.testing.expect(original.data.object.get("nested").?.data.list.items[0].data.string.ptr !=
        cloned.data.object.get("nested").?.data.list.items[0].data.string.ptr);
    try std.testing.expectEqualStrings("deep", cloned.data.object.get("nested").?.data.list.items[0].data.string);
}
