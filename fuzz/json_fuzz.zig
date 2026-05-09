const std = @import("std");

/// JSON-to-GraphQL-Value fuzz harness.
/// Generates random JSON strings, validates them, then feeds them into
/// jsonToGraphQLValue to ensure no crashes or leaks.

const Value = @import("zgraphql").Value;

fn jsonToGraphQLValue(allocator: std.mem.Allocator, json_val: std.json.Value) std.mem.Allocator.Error!Value {
    switch (json_val) {
        .null => return Value.fromNull(allocator),
        .bool => |b| return Value.fromBool(allocator, b),
        .integer => |i| return Value.fromInt(allocator, i),
        .float => |f| return Value.fromFloat(allocator, f),
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |i| {
                return Value.fromInt(allocator, i);
            } else |_| {
                if (std.fmt.parseFloat(f64, s)) |f| {
                    return Value.fromFloat(allocator, f);
                } else |_| {
                    return Value.fromString(allocator, try allocator.dupe(u8, s));
                }
            }
        },
        .string => |s| return Value.fromString(allocator, try allocator.dupe(u8, s)),
        .array => |arr| {
            var list = Value.initList(allocator);
            errdefer list.deinit();
            for (arr.items) |item| {
                try list.data.list.append(try jsonToGraphQLValue(allocator, item));
            }
            return list;
        },
        .object => |obj| {
            var graph_obj = Value.initObject(allocator);
            errdefer graph_obj.deinit();
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try graph_obj.data.object.put(try allocator.dupe(u8, entry.key_ptr.*), try jsonToGraphQLValue(allocator, entry.value_ptr.*));
            }
            return graph_obj;
        },
    }
}

fn generateRandomJsonString(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng, depth: usize) ![]u8 {
    if (depth == 0) {
        const leaf = rng.random().int(u8) % 5;
        return switch (leaf) {
            0 => try allocator.dupe(u8, "null"),
            1 => try allocator.dupe(u8, if (rng.random().boolean()) "true" else "false"),
            2 => try std.fmt.allocPrint(allocator, "{d}", .{rng.random().int(i64)}),
            3 => try std.fmt.allocPrint(allocator, "{d}", .{rng.random().float(f64)}),
            else => try std.fmt.allocPrint(allocator, "\"test\"", .{}),
        };
    }

    const kind = rng.random().int(u8) % 4;
    return switch (kind) {
        0 => try allocator.dupe(u8, "null"),
        1 => try allocator.dupe(u8, if (rng.random().boolean()) "true" else "false"),
        2 => blk: {
            const len = rng.random().intRangeAtMost(usize, 0, 4);
            var buf = std.array_list.Managed(u8).init(allocator);
            defer buf.deinit();
            try buf.append('[');
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (i > 0) try buf.append(',');
                const item = try generateRandomJsonString(allocator, rng, depth - 1);
                defer allocator.free(item);
                try buf.appendSlice(item);
            }
            try buf.append(']');
            break :blk try allocator.dupe(u8, buf.items);
        },
        3 => blk: {
            const len = rng.random().intRangeAtMost(usize, 0, 4);
            var buf = std.array_list.Managed(u8).init(allocator);
            defer buf.deinit();
            try buf.append('{');
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (i > 0) try buf.append(',');
                const key = try std.fmt.allocPrint(allocator, "\"k{d}\"", .{i});
                defer allocator.free(key);
                try buf.appendSlice(key);
                try buf.append(':');
                const val = try generateRandomJsonString(allocator, rng, depth - 1);
                defer allocator.free(val);
                try buf.appendSlice(val);
            }
            try buf.append('}');
            break :blk try allocator.dupe(u8, buf.items);
        },
        else => try allocator.dupe(u8, "null"),
    };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leak = gpa.deinit();
        if (leak != .ok) {
            std.debug.print("FAIL: memory leak detected after fuzz test\n", .{});
            std.process.exit(1);
        }
    }
    const seed: u64 = 0x12345678;
    var rng = std.Random.DefaultPrng.init(seed);

    const iterations = 5_000;
    std.debug.print("JSON fuzz: {d} iterations, seed={d}\n", .{ iterations, seed });

    var ok: usize = 0;
    var leak_detected: usize = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var iter_gpa: std.heap.DebugAllocator(.{}) = .init;
        defer {
            const leak = iter_gpa.deinit();
            if (leak != .ok) leak_detected += 1;
        }
        const iter_alloc = iter_gpa.allocator();

        const json_str = try generateRandomJsonString(iter_alloc, &rng, 2);
        defer iter_alloc.free(json_str);

        const parsed = std.json.parseFromSlice(std.json.Value, iter_alloc, json_str, .{}) catch |e| switch (e) {
            error.OutOfMemory => continue,
            else => continue,
        };
        defer parsed.deinit();

        var gv = jsonToGraphQLValue(iter_alloc, parsed.value) catch |e| switch (e) {
            error.OutOfMemory => continue,
        };
        defer gv.deinit();

        ok += 1;
    }

    std.debug.print("  ok={d}, leaks={d}\n", .{ ok, leak_detected });
    if (leak_detected > 0) {
        std.debug.print("FAIL: {d} iterations leaked memory\n", .{leak_detected});
        std.process.exit(1);
    }
    std.debug.print("PASS\n", .{});
}
