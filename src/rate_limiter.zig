const std = @import("std");

/// Token-bucket rate limiter keyed by arbitrary strings.
/// Thread-safe via a spinlock.
/// Uses integer arithmetic to avoid f64 precision drift in production.
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    buckets: std.StringHashMap(Bucket),
    mutex: std.atomic.Mutex,
    /// Capacity in milli-tokens (1 token = 1000 milli-tokens).
    capacity: i64,
    /// Refill rate in milli-tokens per second.
    refill_rate: i64,

    const Bucket = struct {
        /// Current token balance in milli-tokens.
        tokens: i64,
        last_update_ms: i64,
    };

    /// Create a rate limiter. `capacity` and `refill_rate` are in whole tokens per second.
    /// Internally they are scaled to milli-tokens for precision.
    /// Values are clamped to avoid i64 overflow.
    pub fn init(allocator: std.mem.Allocator, capacity: u64, refill_rate: u64) RateLimiter {
        const max_safe: u64 = @intCast(@divFloor(std.math.maxInt(i64), 1000));
        const cap = if (capacity > max_safe) std.math.maxInt(i64) else @as(i64, @intCast(capacity)) * 1000;
        const rate = if (refill_rate > max_safe) std.math.maxInt(i64) else @as(i64, @intCast(refill_rate)) * 1000;
        return .{
            .allocator = allocator,
            .buckets = std.StringHashMap(Bucket).init(allocator),
            .mutex = .unlocked,
            .capacity = cap,
            .refill_rate = rate,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var iter = self.buckets.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.buckets.deinit();
    }

    fn lockMutex(mutex: *std.atomic.Mutex) void {
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    /// Returns true if the request is allowed, false if rate limited.
    pub fn allow(self: *RateLimiter, key: []const u8, now_ms: i64) bool {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const gop = self.buckets.getOrPut(key) catch return false;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch return false;
            gop.value_ptr.* = .{ .tokens = self.capacity - 1000, .last_update_ms = now_ms };
            return true;
        }

        // Clamp elapsed time to handle clock regression
        const elapsed_ms = if (now_ms > gop.value_ptr.last_update_ms) now_ms - gop.value_ptr.last_update_ms else 0;
        // Refill = (elapsed_ms * refill_rate) / 1000 milliseconds
        const refill = @divFloor(elapsed_ms * self.refill_rate, 1000);
        gop.value_ptr.tokens = @min(self.capacity, gop.value_ptr.tokens + refill);
        gop.value_ptr.last_update_ms = now_ms;

        if (gop.value_ptr.tokens >= 1000) {
            gop.value_ptr.tokens -= 1000;
            return true;
        }
        return false;
    }

    /// Remove a specific key from the rate limiter.
    pub fn remove(self: *RateLimiter, key: []const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.buckets.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    /// Remove entries that haven't been accessed since `older_than_ms`.
    /// Call periodically to prevent unbounded memory growth.
    pub fn prune(self: *RateLimiter, older_than_ms: i64) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var to_remove = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit();
        }

        var iter = self.buckets.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_update_ms < older_than_ms) {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(key) catch {
                    self.allocator.free(key);
                    continue;
                };
            }
        }

        for (to_remove.items) |k| {
            if (self.buckets.fetchRemove(k)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }
};

test "RateLimiter basic" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, 3, 1);
    defer limiter.deinit();

    const key = "client1";
    try std.testing.expect(limiter.allow(key, 0));
    try std.testing.expect(limiter.allow(key, 0));
    try std.testing.expect(limiter.allow(key, 0));
    try std.testing.expect(!limiter.allow(key, 0));

    // After 1 second, 1 token refilled
    try std.testing.expect(limiter.allow(key, 1000));
    try std.testing.expect(!limiter.allow(key, 1000));
}

test "RateLimiter integer precision" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, 100, 10);
    defer limiter.deinit();

    const key = "client2";
    // Consume all tokens
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(limiter.allow(key, 0));
    }
    try std.testing.expect(!limiter.allow(key, 0));

    // After 100ms at 10 tokens/sec, 1 token refilled
    try std.testing.expect(limiter.allow(key, 100));
    try std.testing.expect(!limiter.allow(key, 100));
}
