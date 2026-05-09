const std = @import("std");
const zg = @import("zgraphql");

/// Parser fuzz harness: generates random/mutated GraphQL-like inputs
/// and ensures the parser never crashes or leaks memory.

fn fuzzInput(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]u8 {
    const strategies = [_]struct {
        weight: u32,
        generate: *const fn (std.mem.Allocator, *std.Random.DefaultPrng) std.mem.Allocator.Error![]u8,
    }{
        .{ .weight = 10, .generate = generateRandomGraphQL },
        .{ .weight = 5, .generate = generateMutatedGraphQL },
        .{ .weight = 3, .generate = generateRandomBytes },
        .{ .weight = 2, .generate = generateEdgeCaseInput },
    };

    var total_weight: u32 = 0;
    for (strategies) |s| total_weight += s.weight;

    const roll = rng.random().int(u32) % total_weight;
    var cumulative: u32 = 0;
    for (strategies) |s| {
        cumulative += s.weight;
        if (roll < cumulative) {
            return s.generate(allocator, rng);
        }
    }
    return generateRandomGraphQL(allocator, rng);
}

fn generateRandomGraphQL(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]u8 {
    const fragments = [_][]const u8{
        "{", "}", "(", ")", "[", "]", ",", ":", "query", "mutation",
        "subscription", "fragment", "on", "true", "false", "null",
        "@skip", "@include", "if", "field", "id", "name", "String", "Int",
        "$var", "...", "\"hello\"", "\"", "\\n", "\\t", "    ", "\n", "\r\n",
    };
    const len = rng.random().intRangeAtMost(usize, 0, 4096);
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const idx = rng.random().int(usize) % fragments.len;
        try buf.appendSlice(fragments[idx]);
    }
    return try allocator.dupe(u8, buf.items);
}

fn generateMutatedGraphQL(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]u8 {
    const base = "query GetUser($id: ID!) { user(id: $id) { name email friends { name } } }";
    const len = rng.random().intRangeAtMost(usize, 0, base.len);
    return try allocator.dupe(u8, base[0..len]);
}

fn generateRandomBytes(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]u8 {
    const len = rng.random().intRangeAtMost(usize, 0, 1024);
    const buf = try allocator.alloc(u8, len);
    for (buf) |*b| {
        b.* = rng.random().int(u8);
    }
    return buf;
}

fn generateEdgeCaseInput(allocator: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]u8 {
    const inputs = [_][]const u8{
        "",
        "{",
        "}",
        "{ ",
        " query ",
        "query { }",
        "{ field { field { field { field { field } } } } }",
        "\"" ** 10000,
        "..." ** 1000,
        "{ a(b: { c: { d: { e: { f: 1 } } } }) }",
    };
    const idx = rng.random().int(usize) % inputs.len;
    return try allocator.dupe(u8, inputs[idx]);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const seed: u64 = 0x12345678;
    var rng = std.Random.DefaultPrng.init(seed);

    const iterations = 10_000;
    std.debug.print("Parser fuzz: {d} iterations, seed={d}\n", .{ iterations, seed });

    var parse_ok: usize = 0;
    var parse_err: usize = 0;
    var leak_detected: usize = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var iter_gpa: std.heap.DebugAllocator(.{}) = .init;
        defer {
            const leak = iter_gpa.deinit();
            if (leak != .ok) leak_detected += 1;
        }
        const iter_alloc = iter_gpa.allocator();

        const input = try fuzzInput(allocator, &rng);
        defer allocator.free(input);

        var parser = zg.Parser.init(iter_alloc, input) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => continue,
        };
        defer parser.deinit();

        var doc = parser.parseDocument() catch |err| switch (err) {
            else => {
                parse_err += 1;
                continue;
            },
        };
        defer doc.deinit();

        parse_ok += 1;
    }

    std.debug.print("  parse_ok={d}, parse_err={d}, leaks={d}\n", .{ parse_ok, parse_err, leak_detected });
    if (leak_detected > 0) {
        std.debug.print("FAIL: {d} iterations leaked memory\n", .{leak_detected});
        std.process.exit(1);
    }
    std.debug.print("PASS\n", .{});
}
