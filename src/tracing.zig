const std = @import("std");
const Io = std.Io;

/// Lightweight distributed tracing support compatible with OpenTelemetry/W3C.
///
/// Usage:
///   var tracer = Tracer.init(allocator, io);
///   defer tracer.deinit();
///
///   var span = try tracer.startRootSpan("graphql.execute", randomTraceId(io));
///   defer tracer.endSpan(&span);
///   // ... do work ...
///
///   const json = try tracer.exportJson(allocator);

pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

pub const TraceSpan = struct {
    name: []const u8,
    trace_id: TraceId,
    span_id: SpanId,
    parent_id: ?SpanId,
    start_ns: i128,
    end_ns: i128 = 0,
    attributes: std.StringHashMap([]const u8),

    pub fn deinit(self: *TraceSpan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        var iter = self.attributes.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
    }

    pub fn setAttribute(self: *TraceSpan, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        try self.attributes.put(k, v);
    }

    pub fn durationNs(self: TraceSpan) i128 {
        return self.end_ns - self.start_ns;
    }
};

pub const TraceContext = struct {
    trace_id: TraceId,
    parent_span_id: SpanId,
};

/// Simple in-memory tracer. Collects spans for export.
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    spans: std.array_list.Managed(TraceSpan),
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: Io) Tracer {
        return .{
            .allocator = allocator,
            .io = io,
            .spans = std.array_list.Managed(TraceSpan).init(allocator),
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.spans.items) |*span| {
            span.deinit(self.allocator);
        }
        self.spans.deinit();
    }

    pub fn startRootSpan(self: *Tracer, name: []const u8, trace_id: TraceId) std.mem.Allocator.Error!TraceSpan {
        return .{
            .name = try self.allocator.dupe(u8, name),
            .trace_id = trace_id,
            .span_id = randomSpanId(self.io),
            .parent_id = null,
            .start_ns = nowNs(self.io),
            .attributes = std.StringHashMap([]const u8).init(self.allocator),
        };
    }

    pub fn startChildSpan(self: *Tracer, name: []const u8, parent: *TraceSpan) std.mem.Allocator.Error!TraceSpan {
        return .{
            .name = try self.allocator.dupe(u8, name),
            .trace_id = parent.trace_id,
            .span_id = randomSpanId(self.io),
            .parent_id = parent.span_id,
            .start_ns = nowNs(self.io),
            .attributes = std.StringHashMap([]const u8).init(self.allocator),
        };
    }

    pub fn endSpan(self: *Tracer, span: TraceSpan) void {
        var s = span;
        s.end_ns = nowNs(self.io);
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.spans.append(s) catch {};
    }

    /// Export all collected spans as a JSON array (OpenTelemetry-ish format).
    /// Caller owns the returned string.
    pub fn exportJson(self: *Tracer, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();

        try buf.appendSlice("[\n");
        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try buf.appendSlice(",\n");
            try buf.appendSlice("  {\n");

            try buf.appendSlice("    \"name\": \"");
            try buf.appendSlice(span.name);
            try buf.appendSlice("\",\n");

            {
                const hex = std.fmt.bytesToHex(&span.trace_id, .lower);
                try buf.appendSlice("    \"traceId\": \"");
                try buf.appendSlice(&hex);
                try buf.appendSlice("\",\n");
            }

            {
                const hex = std.fmt.bytesToHex(&span.span_id, .lower);
                try buf.appendSlice("    \"spanId\": \"");
                try buf.appendSlice(&hex);
                try buf.appendSlice("\",\n");
            }

            if (span.parent_id) |pid| {
                const hex = std.fmt.bytesToHex(&pid, .lower);
                try buf.appendSlice("    \"parentId\": \"");
                try buf.appendSlice(&hex);
                try buf.appendSlice("\",\n");
            }

            try buf.appendSlice("    \"startTime\": ");
            try appendInt(&buf, span.start_ns);
            try buf.appendSlice(",\n");
            try buf.appendSlice("    \"endTime\": ");
            try appendInt(&buf, span.end_ns);
            try buf.appendSlice(",\n");
            try buf.appendSlice("    \"durationNs\": ");
            try appendInt(&buf, span.durationNs());

            if (span.attributes.count() > 0) {
                try buf.appendSlice(",\n    \"attributes\": {\n");
                var aiter = span.attributes.iterator();
                var afirst = true;
                while (aiter.next()) |entry| {
                    if (!afirst) try buf.appendSlice(",\n");
                    afirst = false;
                    try buf.appendSlice("      \"");
                    try buf.appendSlice(entry.key_ptr.*);
                    try buf.appendSlice("\": \"");
                    try buf.appendSlice(entry.value_ptr.*);
                    try buf.appendSlice("\"");
                }
                try buf.appendSlice("\n    }");
            }

            try buf.appendSlice("\n  }");
        }
        try buf.appendSlice("\n]");

        return buf.toOwnedSlice();
    }

    fn appendInt(buf: *std.array_list.Managed(u8), n: i128) !void {
        var tmp: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
        };
        try buf.appendSlice(s);
    }


};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

fn nowNs(io: Io) i128 {
    const ts = Io.Clock.Timestamp.now(io, .real);
    return ts.raw.nanoseconds;
}

/// Parse a W3C traceparent header.
/// Format: `00-<trace_id>-<span_id>-<flags>`
/// Returns null if malformed.
pub fn parseTraceparent(header: []const u8) ?TraceContext {
    if (header.len < 55) return null;
    if (!std.mem.eql(u8, header[0..2], "00")) return null;
    if (header[2] != '-') return null;

    var trace_id: TraceId = undefined;
    var span_id: SpanId = undefined;

    if (!parseHexBytes(header[3..35], &trace_id)) return null;
    if (header[35] != '-') return null;
    if (!parseHexBytes(header[36..52], &span_id)) return null;

    return .{
        .trace_id = trace_id,
        .parent_span_id = span_id,
    };
}

/// Format a traceparent header into `buf`. Returns the written slice.
/// `buf` must be at least 55 bytes.
pub fn formatTraceparent(buf: []u8, ctx: TraceContext) []const u8 {
    const trace_hex = std.fmt.bytesToHex(&ctx.trace_id, .lower);
    const span_hex = std.fmt.bytesToHex(&ctx.parent_span_id, .lower);
    return std.fmt.bufPrint(buf, "00-{s}-{s}-01", .{ trace_hex, span_hex }) catch unreachable;
}

fn parseHexBytes(hex: []const u8, out: []u8) bool {
    if (hex.len != out.len * 2) return false;
    for (out, 0..) |*b, i| {
        const hi = std.fmt.charToDigit(hex[i * 2], 16) catch return false;
        const lo = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return false;
        b.* = @intCast(hi * 16 + lo);
    }
    return true;
}

pub fn randomTraceId(io: Io) TraceId {
    var id: TraceId = undefined;
    Io.random(io, &id);
    return id;
}

pub fn randomSpanId(io: Io) SpanId {
    var id: SpanId = undefined;
    Io.random(io, &id);
    return id;
}

test "traceparent parse and format" {
    const header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const ctx = parseTraceparent(header).?;

    var buf: [64]u8 = undefined;
    const formatted = formatTraceparent(&buf, ctx);
    try std.testing.expectEqualStrings(header, formatted);
}

test "tracer basic" {
    const allocator = std.testing.allocator;
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();
    const io = backend.io();

    var tracer = Tracer.init(allocator, io);
    defer tracer.deinit();

    const trace_id = randomTraceId(io);
    const span = try tracer.startRootSpan("test.operation", trace_id);

    // Yield briefly
    Io.sleep(io, Io.Duration.fromNanoseconds(1_000_000), .awake) catch {};

    tracer.endSpan(span);

    const json = try tracer.exportJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "test.operation") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "traceId") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "durationNs") != null);
}
