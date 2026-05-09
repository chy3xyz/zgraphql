const std = @import("std");

/// Managed ArrayList alias for convenience.
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// GraphQL Value representation.
/// Maps directly to the GraphQL specification's value types.
pub const Value = struct {
    allocator: std.mem.Allocator,
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

    pub fn fromNull(allocator: std.mem.Allocator) Value {
        return .{ .allocator = allocator, .data = .{ .null = {} } };
    }

    pub fn fromInt(allocator: std.mem.Allocator, v: i64) Value {
        return .{ .allocator = allocator, .data = .{ .int = v } };
    }

    pub fn fromFloat(allocator: std.mem.Allocator, v: f64) Value {
        return .{ .allocator = allocator, .data = .{ .float = v } };
    }

    /// Takes ownership of the string slice.
    pub fn fromString(allocator: std.mem.Allocator, v: []const u8) Value {
        return .{ .allocator = allocator, .data = .{ .string = v } };
    }

    pub fn fromBool(allocator: std.mem.Allocator, v: bool) Value {
        return .{ .allocator = allocator, .data = .{ .boolean = v } };
    }

    /// Takes ownership of the string slice.
    pub fn fromEnum(allocator: std.mem.Allocator, v: []const u8) Value {
        return .{ .allocator = allocator, .data = .{ .enum_value = v } };
    }

    pub fn initList(allocator: std.mem.Allocator) Value {
        return .{ .allocator = allocator, .data = .{ .list = ArrayList(Value).init(allocator) } };
    }

    pub fn initObject(allocator: std.mem.Allocator) Value {
        return .{ .allocator = allocator, .data = .{ .object = std.StringHashMap(Value).init(allocator) } };
    }

    pub fn deinit(self: *Value) void {
        switch (self.data) {
            .string => |v| self.allocator.free(v),
            .enum_value => |v| self.allocator.free(v),
            .list => |*list| {
                for (list.items) |*item| {
                    item.deinit();
                }
                list.deinit();
            },
            .object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit();
                }
                obj.deinit();
            },
            else => {},
        }
    }

    /// Deep clone a value.
    pub fn clone(self: Value) std.mem.Allocator.Error!Value {
        const allocator = self.allocator;
        switch (self.data) {
            .null => return fromNull(allocator),
            .int => |v| return fromInt(allocator, v),
            .float => |v| return fromFloat(allocator, v),
            .string => |v| return fromString(allocator, try allocator.dupe(u8, v)),
            .boolean => |v| return fromBool(allocator, v),
            .enum_value => |v| return fromEnum(allocator, try allocator.dupe(u8, v)),
            .list => |list| {
                var new = initList(allocator);
                errdefer new.deinit();
                for (list.items) |item| {
                    try new.data.list.append(try item.clone());
                }
                return new;
            },
            .object => |obj| {
                var new = initObject(allocator);
                errdefer new.deinit();
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    try new.data.object.put(key, try entry.value_ptr.clone());
                }
                return new;
            },
        }
    }

    pub const JsonError = std.mem.Allocator.Error || std.Io.Writer.Error;

    /// Serialize to JSON. Caller owns the returned string.
    pub fn toJson(self: Value) JsonError![]const u8 {
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        try self.writeJson(&allocating.writer);
        var arr = allocating.toArrayList();
        return arr.toOwnedSlice(self.allocator);
    }

    pub fn writeJson(self: Value, writer: *std.Io.Writer) JsonError!void {
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
                    try item.writeJson(writer);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                // Sort keys for deterministic output
                var sorted = ArrayList([]const u8).init(obj.allocator);
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
                    try obj.get(key).?.writeJson(writer);
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

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const json_str = try self.toJson();
        defer self.allocator.free(json_str);
        try writer.writeAll(json_str);
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
    const null_json = try null_val.toJson();
    defer allocator.free(null_json);
    try std.testing.expectEqualStrings("null", null_json);
    null_val.deinit();

    // Int
    var int_val = Value.fromInt(allocator, 42);
    const int_json = try int_val.toJson();
    defer allocator.free(int_json);
    try std.testing.expectEqualStrings("42", int_json);
    int_val.deinit();

    // String with escaping
    const str_dup = try allocator.dupe(u8, "hello\nworld\"\\");
    var str_val = Value.fromString(allocator, str_dup);
    const str_json = try str_val.toJson();
    defer allocator.free(str_json);
    try std.testing.expectEqualStrings("\"hello\\nworld\\\"\\\\\"", str_json);
    str_val.deinit();

    // List
    var list = Value.initList(allocator);
    try list.data.list.append(Value.fromInt(allocator, 1));
    try list.data.list.append(Value.fromString(allocator, try allocator.dupe(u8, "two")));
    const list_json = try list.toJson();
    defer allocator.free(list_json);
    try std.testing.expectEqualStrings("[1,\"two\"]", list_json);
    list.deinit();

    // Object
    var obj = Value.initObject(allocator);
    try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, "Alice")));
    try obj.data.object.put(try allocator.dupe(u8, "age"), Value.fromInt(allocator, 30));
    const obj_json = try obj.toJson();
    defer allocator.free(obj_json);
    try std.testing.expectEqualStrings("{\"age\":30,\"name\":\"Alice\"}", obj_json);
    obj.deinit();
}

test "value clone" {
    const allocator = std.testing.allocator;
    var original = Value.initObject(allocator);
    try original.data.object.put(try allocator.dupe(u8, "nested"), Value.initList(allocator));
    var nested_list = original.data.object.getPtr("nested").?;
    try nested_list.data.list.append(Value.fromString(allocator, try allocator.dupe(u8, "deep")));

    var cloned = try original.clone();
    defer cloned.deinit();
    defer original.deinit();

    try std.testing.expect(original.data.object.get("nested").?.data.list.items[0].data.string.ptr !=
        cloned.data.object.get("nested").?.data.list.items[0].data.string.ptr);
    try std.testing.expectEqualStrings("deep", cloned.data.object.get("nested").?.data.list.items[0].data.string);
}
