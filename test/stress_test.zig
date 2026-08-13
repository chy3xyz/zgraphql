const std = @import("std");
const zg = @import("zgraphql");
const Io = std.Io;

/// Long-running stress test to validate memory stability and performance
/// under sustained load. Run for 30-60 seconds in CI or manually.

fn buildSchema(allocator: std.mem.Allocator) !zg.schema.Schema {
    const query_type = try allocator.create(zg.schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };

    var hello_field = zg.schema.Field.init(allocator, "hello", zg.schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
            return zg.Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var user_type = try allocator.create(zg.schema.Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = zg.schema.ObjectType.init(allocator) },
    };
    var name_field = zg.schema.Field.init(allocator, "name", zg.schema.TypeRef.named("String"));
    name_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
            return zg.Value.fromString(alloc, try alloc.dupe(u8, "Alice"));
        }
    }.resolve;
    try user_type.kind.object.fields.put(try allocator.dupe(u8, "name"), name_field);

    var user_field = zg.schema.Field.init(allocator, "user", zg.schema.TypeRef.named("User"));
    user_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.Value {
            var obj = zg.Value.initObject(alloc);
            try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, "Alice")));
            return obj;
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "user"), user_field);

    var schema_def = try zg.schema.Schema.init(allocator, query_type);
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("User", user_type);
    return schema_def;
}

fn runIteration(allocator: std.mem.Allocator, schema_def: *zg.schema.Schema, io: std.Io, idx: usize) !void {
    const queries = [_][]const u8{
        "{ hello }",
        "{ user { name } }",
        "{ hello user { name } }",
        "query Q { hello }",
    };

    const q = queries[idx % queries.len];

    var parser = try zg.Parser.init(allocator, q);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = zg.Validator.init(allocator, schema_def);
    defer validator.deinit();
    const vresult = try validator.validate(&doc);
    if (!vresult.isValid()) return error.ValidationFailed;

    var executor = zg.Executor.init(allocator, schema_def, io);
    defer executor.deinit();
    var result = try executor.execute(&doc);
    defer result.deinit();

    const json_str = try result.toJson();
    defer allocator.free(json_str);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leak = gpa.deinit();
        if (leak != .ok) {
            std.debug.print("FAIL: memory leak detected after stress test\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    var schema_def = try buildSchema(allocator);
    defer schema_def.deinit();

    const duration_sec = 30;

    const start_ts = Io.Clock.Timestamp.now(io, .real);
    const start = @divFloor(start_ts.raw.nanoseconds, std.time.ns_per_ms);
    var iterations: usize = 0;

    std.debug.print("Stress test: {d} seconds of sustained parse/validate/execute...\n", .{duration_sec});

    while (true) {
        const now_ts = Io.Clock.Timestamp.now(io, .real);
        const now_ms = @divFloor(now_ts.raw.nanoseconds, std.time.ns_per_ms);
        if (now_ms - start >= duration_sec * 1000) break;
        try runIteration(allocator, &schema_def, io, iterations);
        iterations += 1;
    }

    const end_ts = Io.Clock.Timestamp.now(io, .real);
    const end_ms = @divFloor(end_ts.raw.nanoseconds, std.time.ns_per_ms);
    const elapsed_ms = @as(f64, @floatFromInt(end_ms - start));
    const qps = @as(f64, @floatFromInt(iterations)) / (elapsed_ms / 1000.0);

    std.debug.print("Completed {d} iterations (~{d:.0} ops/sec)\n", .{ iterations, qps });
    std.debug.print("PASS\n", .{});
}
