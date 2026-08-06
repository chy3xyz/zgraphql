const std = @import("std");
const zg = @import("zgraphql");

const Io = std.Io;

fn nowNs(io: Io) i128 {
    const ts = Io.Clock.Timestamp.now(io, .real);
    return ts.raw.nanoseconds;
}

const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: i128,
    avg_ns: f64,
    min_ns: i128,
    max_ns: i128,

    pub fn print(self: BenchmarkResult) void {
        var avg_buf: [64]u8 = undefined;
        const avg_str = std.fmt.bufPrint(&avg_buf, "{d:.2}", .{self.avg_ns}) catch "???";
        std.debug.print("{s:34} {d:>8} iter  {s:>10} ns/avg  {d:>10} ns/min  {d:>10} ns/max\n", .{
            self.name,
            self.iterations,
            avg_str,
            self.min_ns,
            self.max_ns,
        });
    }
};

fn runBenchmark(
    comptime name: []const u8,
    io: Io,
    iterations: usize,
    bench_fn: *const fn (allocator: std.mem.Allocator, io: Io) anyerror!void,
    allocator: std.mem.Allocator,
) !BenchmarkResult {
    // Warm-up: let the allocator and scheduler reach steady state before timing.
    {
        var w: usize = 0;
        while (w < iterations / 10) : (w += 1) {
            try bench_fn(allocator, io);
        }
    }

    var total_ns: i128 = 0;
    var min_ns: i128 = std.math.maxInt(i128);
    var max_ns: i128 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = nowNs(io);
        try bench_fn(allocator, io);
        const end = nowNs(io);
        const elapsed = end - start;
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations)),
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

fn benchParse(allocator: std.mem.Allocator, io: Io) !void {
    _ = io;
    var parser = try zg.Parser.init(allocator, "{ hello world foo(bar: 1) { nested } }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();
}

fn buildQuerySchema(allocator: std.mem.Allocator) !zg.schema.Schema {
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

    var schema_def = zg.schema.Schema.init(allocator, query_type);
    try schema_def.registerType("Query", query_type);
    return schema_def;
}

fn benchValidate(allocator: std.mem.Allocator, io: Io) !void {
    _ = io;
    var schema_def = try buildQuerySchema(allocator);
    defer schema_def.deinit();

    var parser = try zg.Parser.init(allocator, "{ hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = zg.Validator.init(allocator, &schema_def);
    defer validator.deinit();
    _ = try validator.validate(&doc);
}

fn benchExecute(allocator: std.mem.Allocator, io: Io) !void {
    var schema_def = try buildQuerySchema(allocator);
    defer schema_def.deinit();

    var parser = try zg.Parser.init(allocator, "{ hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var executor = zg.Executor.init(allocator, &schema_def, io);
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();
}

fn benchEndToEnd(allocator: std.mem.Allocator, io: Io) !void {
    var schema_def = try buildQuerySchema(allocator);
    defer schema_def.deinit();

    var parser = try zg.Parser.init(allocator, "{ hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = zg.Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const vresult = try validator.validate(&doc);
    if (!vresult.isValid()) return error.ValidationFailed;

    var executor = zg.Executor.init(allocator, &schema_def, io);
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    const json_str = try result.toJson();
    defer allocator.free(json_str);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    // Keep iterations modest so the benchmark finishes quickly under Debug.
    // Build with -Doptimize=ReleaseFast for representative numbers.
    const iterations = 2000;

    std.debug.print("\n=== zgraphql Performance Benchmark ===\n", .{});
    std.debug.print("Iterations per benchmark: {d} (build with -Doptimize=ReleaseFast for production numbers)\n\n", .{iterations});

    const parse_result = try runBenchmark("Parse simple query", io, iterations, benchParse, allocator);
    parse_result.print();

    const validate_result = try runBenchmark("Validate simple query", io, iterations, benchValidate, allocator);
    validate_result.print();

    const execute_result = try runBenchmark("Execute simple query", io, iterations, benchExecute, allocator);
    execute_result.print();

    const e2e_result = try runBenchmark("End-to-end (parse+validate+execute+json)", io, iterations, benchEndToEnd, allocator);
    e2e_result.print();

    std.debug.print("\n", .{});
}
