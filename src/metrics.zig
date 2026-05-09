const std = @import("std");

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// Per-resolver metrics bucket.
pub const ResolverMetrics = struct {
    calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_duration_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_duration_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Production-grade metrics collector for GraphQL server observability.
/// Lock-free for global counters; spinlock-protected for resolver-level buckets.
pub const MetricsCollector = struct {
    allocator: ?std.mem.Allocator = null,
    queries_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queries_error: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Timing (nanoseconds)
    query_duration_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    query_duration_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    query_duration_min_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(std.math.maxInt(u64)),

    // Complexity
    total_complexity: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    max_complexity: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Resolver-level metrics
    resolver_metrics: std.StringHashMap(ResolverMetrics),
    resolver_mutex: std.atomic.Mutex,

    pub const Snapshot = struct {
        queries_total: u64,
        queries_error: u64,
        avg_duration_ms: f64,
        max_duration_ms: f64,
        min_duration_ms: f64,
        avg_complexity: f64,
        max_complexity: u64,
    };

    pub fn init(allocator: std.mem.Allocator) MetricsCollector {
        return .{
            .allocator = allocator,
            .resolver_metrics = std.StringHashMap(ResolverMetrics).init(allocator),
            .resolver_mutex = .unlocked,
        };
    }

    pub fn deinit(self: *MetricsCollector) void {
        var iter = self.resolver_metrics.iterator();
        while (iter.next()) |entry| {
            if (self.allocator) |a| a.free(entry.key_ptr.*);
        }
        self.resolver_metrics.deinit();
    }

    /// Record a completed query.
    pub fn recordQuery(self: *MetricsCollector, duration_ns: u64, complexity: u64, had_error: bool) void {
        _ = self.queries_total.fetchAdd(1, .monotonic);
        if (had_error) _ = self.queries_error.fetchAdd(1, .monotonic);
        _ = self.query_duration_ns.fetchAdd(duration_ns, .monotonic);

        // Update max duration (CAS loop)
        var current_max = self.query_duration_max_ns.load(.monotonic);
        while (duration_ns > current_max) {
            current_max = self.query_duration_max_ns.cmpxchgWeak(
                current_max,
                duration_ns,
                .monotonic,
                .monotonic,
            ) orelse break;
        }

        // Update min duration (CAS loop)
        var current_min = self.query_duration_min_ns.load(.monotonic);
        while (duration_ns < current_min) {
            current_min = self.query_duration_min_ns.cmpxchgWeak(
                current_min,
                duration_ns,
                .monotonic,
                .monotonic,
            ) orelse break;
        }

        _ = self.total_complexity.fetchAdd(complexity, .monotonic);

        // Update max complexity (CAS loop)
        var current_max_comp = self.max_complexity.load(.monotonic);
        while (complexity > current_max_comp) {
            current_max_comp = self.max_complexity.cmpxchgWeak(
                current_max_comp,
                complexity,
                .monotonic,
                .monotonic,
            ) orelse break;
        }
    }

    /// Record a resolver invocation.
    pub fn recordResolver(self: *MetricsCollector, field_name: []const u8, duration_ns: u64, had_error: bool) void {
        lockMutex(&self.resolver_mutex);
        defer self.resolver_mutex.unlock();

        const allocator = self.allocator orelse return;
        const gop = self.resolver_metrics.getOrPut(field_name) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = allocator.dupe(u8, field_name) catch return;
            gop.value_ptr.* = .{};
        }

        _ = gop.value_ptr.calls.fetchAdd(1, .monotonic);
        if (had_error) _ = gop.value_ptr.errors.fetchAdd(1, .monotonic);
        _ = gop.value_ptr.total_duration_ns.fetchAdd(duration_ns, .monotonic);

        var current_max = gop.value_ptr.max_duration_ns.load(.monotonic);
        while (duration_ns > current_max) {
            current_max = gop.value_ptr.max_duration_ns.cmpxchgWeak(
                current_max,
                duration_ns,
                .monotonic,
                .monotonic,
            ) orelse break;
        }
    }

    /// Get a snapshot of current metrics.
    pub fn snapshot(self: *MetricsCollector) Snapshot {
        const total = self.queries_total.load(.acquire);
        return .{
            .queries_total = total,
            .queries_error = self.queries_error.load(.acquire),
            .avg_duration_ms = if (total > 0)
                @as(f64, @floatFromInt(self.query_duration_ns.load(.acquire))) / @as(f64, @floatFromInt(total)) / 1_000_000.0
            else
                0.0,
            .max_duration_ms = @as(f64, @floatFromInt(self.query_duration_max_ns.load(.acquire))) / 1_000_000.0,
            .min_duration_ms = blk: {
                const min = self.query_duration_min_ns.load(.acquire);
                break :blk if (total > 0 and min != std.math.maxInt(u64))
                    @as(f64, @floatFromInt(min)) / 1_000_000.0
                else
                    0.0;
            },
            .avg_complexity = if (total > 0)
                @as(f64, @floatFromInt(self.total_complexity.load(.acquire))) / @as(f64, @floatFromInt(total))
            else
                0.0,
            .max_complexity = self.max_complexity.load(.acquire),
        };
    }

    const ResolverExport = struct {
        name: []const u8,
        calls: u64,
        errors: u64,
        avg_duration_ms: f64,
        max_duration_ms: f64,
    };

    const Export = struct {
        queries_total: u64,
        queries_error: u64,
        avg_duration_ms: f64,
        max_duration_ms: f64,
        min_duration_ms: f64,
        avg_complexity: f64,
        max_complexity: u64,
        resolvers: []const ResolverExport,
    };

    /// Serialize metrics to a JSON string. Caller owns the returned memory.
    pub fn toJson(self: *MetricsCollector, allocator: std.mem.Allocator) ![]const u8 {
        const s = self.snapshot();

        lockMutex(&self.resolver_mutex);
        defer self.resolver_mutex.unlock();

        var resolvers = std.array_list.Managed(ResolverExport).init(allocator);
        defer resolvers.deinit();

        var iter = self.resolver_metrics.iterator();
        while (iter.next()) |entry| {
            const calls = entry.value_ptr.calls.load(.acquire);
            const total_ns = entry.value_ptr.total_duration_ns.load(.acquire);
            const avg_ms = if (calls > 0)
                @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(calls)) / 1_000_000.0
            else
                0.0;
            try resolvers.append(.{
                .name = entry.key_ptr.*,
                .calls = calls,
                .errors = entry.value_ptr.errors.load(.acquire),
                .avg_duration_ms = avg_ms,
                .max_duration_ms = @as(f64, @floatFromInt(entry.value_ptr.max_duration_ns.load(.acquire))) / 1_000_000.0,
            });
        }

        const export_data = Export{
            .queries_total = s.queries_total,
            .queries_error = s.queries_error,
            .avg_duration_ms = s.avg_duration_ms,
            .max_duration_ms = s.max_duration_ms,
            .min_duration_ms = s.min_duration_ms,
            .avg_complexity = s.avg_complexity,
            .max_complexity = s.max_complexity,
            .resolvers = resolvers.items,
        };

        return try std.json.Stringify.valueAlloc(allocator, export_data, .{});
    }
};

test "metrics collector basic" {
    const allocator = std.testing.allocator;
    var m = MetricsCollector.init(allocator);
    defer m.deinit();

    m.recordQuery(1_000_000, 10, false); // 1ms
    m.recordQuery(2_000_000, 20, true); // 2ms
    m.recordQuery(3_000_000, 5, false); // 3ms

    const s = m.snapshot();
    try std.testing.expectEqual(@as(u64, 3), s.queries_total);
    try std.testing.expectEqual(@as(u64, 1), s.queries_error);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), s.avg_duration_ms, 0.01); // (1+2+3)/3 = 2ms
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), s.max_duration_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s.min_duration_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 11.666), s.avg_complexity, 0.01);
    try std.testing.expectEqual(@as(u64, 20), s.max_complexity);
}

test "metrics resolver tracking" {
    const allocator = std.testing.allocator;
    var m = MetricsCollector.init(allocator);
    defer m.deinit();

    m.recordResolver("Query.user", 500_000, false);
    m.recordResolver("Query.user", 1_000_000, false);
    m.recordResolver("Query.user", 300_000, true);

    lockMutex(&m.resolver_mutex);
    defer m.resolver_mutex.unlock();
    const rm = m.resolver_metrics.get("Query.user").?;
    try std.testing.expectEqual(@as(u64, 3), rm.calls.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), rm.errors.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1_800_000), rm.total_duration_ns.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1_000_000), rm.max_duration_ns.load(.acquire));
}

test "metrics toJson" {
    const allocator = std.testing.allocator;
    var m = MetricsCollector.init(allocator);
    defer m.deinit();
    m.recordQuery(1_000_000, 10, false);

    const json_str = try m.toJson(allocator);
    defer allocator.free(json_str);

    try std.testing.expect(json_str.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "queries_total") != null);
}
