const std = @import("std");
const Value = @import("value.zig").Value;
const ResponseCache = @import("response_cache.zig").ResponseCache;

/// A cache backend interface. Implementations provide the actual
/// network/storage layer for distributed caching.
///
/// Users can plug in Redis, Memcached, or any custom backend by
/// providing get/set/delete function pointers.
pub const CacheBackend = struct {
    get: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]const u8,
    set: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_ms: u32) anyerror!void,
    delete: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!void,
    ctx: ?*anyopaque = null,
};

/// DistributedCache provides a two-tier caching layer:
///   L1: optional local ResponseCache (fast, same-process)
///   L2: remote CacheBackend (shared across processes/nodes)
///
/// Cache keys are prefixed to avoid collisions when multiple
/// services share the same backend.
pub const DistributedCache = struct {
    allocator: std.mem.Allocator,
    backend: CacheBackend,
    prefix: []const u8,
    local_l1: ?*ResponseCache,
    /// Whether to populate L1 on L2 hits.
    l1_backfill: bool,
    /// Default TTL in milliseconds when none is provided.
    default_ttl_ms: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: CacheBackend,
        prefix: []const u8,
        local_l1: ?*ResponseCache,
    ) DistributedCache {
        return .{
            .allocator = allocator,
            .backend = backend,
            .prefix = prefix,
            .local_l1 = local_l1,
            .l1_backfill = true,
            .default_ttl_ms = if (local_l1) |l1| l1.default_ttl_ms else 5000,
        };
    }

    pub fn deinit(self: *DistributedCache) void {
        self.allocator.free(self.prefix);
    }

    fn makeKey(self: *DistributedCache, raw: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, raw });
    }

    /// Look up a cached response.
    ///   1. Check L1 (local ResponseCache)
    ///   2. If L1 miss, check L2 (distributed backend)
    ///   3. If L2 hit and l1_backfill is enabled, populate L1
    pub fn get(self: *DistributedCache, raw_key: []const u8, now_ms: i64) !?[]const u8 {
        // L1 check
        if (self.local_l1) |l1| {
            if (l1.get(raw_key, now_ms)) |cached| {
                return try self.allocator.dupe(u8, cached);
            }
        }

        // L2 check
        const key = try self.makeKey(raw_key);
        defer self.allocator.free(key);

        if (try self.backend.get(self.backend.ctx, self.allocator, key)) |value| {
            defer self.allocator.free(value);

            // Backfill L1
            if (self.local_l1) |l1| {
                if (self.l1_backfill) {
                    l1.put(raw_key, value, now_ms) catch {};
                }
            }
            return try self.allocator.dupe(u8, value);
        }
        return null;
    }

    /// Store a response. Updates both L1 and L2.
    pub fn set(self: *DistributedCache, raw_key: []const u8, value: []const u8, ttl_ms: u32, now_ms: i64) !void {
        // Update L1
        if (self.local_l1) |l1| {
            l1.put(raw_key, value, now_ms) catch {};
        }

        // Update L2
        const key = try self.makeKey(raw_key);
        defer self.allocator.free(key);
        try self.backend.set(self.backend.ctx, self.allocator, key, value, ttl_ms);
    }

    /// Store a response using the default TTL configured at init time.
    pub fn setWithDefaultTtl(self: *DistributedCache, raw_key: []const u8, value: []const u8, now_ms: i64) !void {
        try self.set(raw_key, value, @intCast(self.default_ttl_ms), now_ms);
    }

    /// Remove an entry from both L1 and L2.
    pub fn delete(self: *DistributedCache, raw_key: []const u8) !void {
        if (self.local_l1) |l1| {
            // ResponseCache does not expose delete; we rely on TTL eviction.
            _ = l1;
        }
        const key = try self.makeKey(raw_key);
        defer self.allocator.free(key);
        try self.backend.delete(self.backend.ctx, self.allocator, key);
    }

    /// Convenience: store a GraphQL Value directly (serializes to JSON).
    pub fn setValue(self: *DistributedCache, raw_key: []const u8, value: Value, ttl_ms: u32, now_ms: i64) !void {
        const json_str = try value.toJson();
        defer self.allocator.free(json_str);
        try self.set(raw_key, json_str, ttl_ms, now_ms);
    }
};

/// HttpCacheBackend is a built-in distributed cache backend that
/// communicates with a remote cache service over HTTP/1.1.
///
/// Expected REST API on the remote service:
///   GET  /{key}          -> 200 with body, or 404
///   PUT  /{key}?ttl={ms} -> store body with TTL
///   DELETE /{key}        -> remove entry
///
/// This backend uses std.http.Client (synchronous). When running
/// inside an std.Io fiber, the blocking I/O will yield automatically.
pub const HttpCacheBackend = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !HttpCacheBackend {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .base_url = try allocator.dupe(u8, base_url),
        };
    }

    pub fn deinit(self: *HttpCacheBackend) void {
        self.client.deinit();
        self.allocator.free(self.base_url);
    }

    pub fn cacheBackend(self: *HttpCacheBackend) CacheBackend {
        return .{
            .get = getImpl,
            .set = setImpl,
            .delete = deleteImpl,
            .ctx = self,
        };
    }

    fn getImpl(ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const self = @as(*HttpCacheBackend, @ptrCast(@alignCast(ctx.?)));
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.base_url, key });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try self.client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buffer,
            .keep_alive = true,
        });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) return null;
        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        return body;
    }

    fn setImpl(ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_ms: u32) !void {
        const self = @as(*HttpCacheBackend, @ptrCast(@alignCast(ctx.?)));
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}?ttl={d}", .{ self.base_url, key, ttl_ms });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try self.client.open(.PUT, uri, .{
            .server_header_buffer = &server_header_buffer,
            .keep_alive = true,
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = value.len };
        try req.send();
        try req.writeAll(value);
        try req.finish();
        try req.wait();
    }

    fn deleteImpl(ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) !void {
        const self = @as(*HttpCacheBackend, @ptrCast(@alignCast(ctx.?)));
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.base_url, key });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try self.client.open(.DELETE, uri, .{
            .server_header_buffer = &server_header_buffer,
            .keep_alive = true,
        });
        defer req.deinit();
        try req.send();
        try req.finish();
        try req.wait();
    }
};

/// SimpleMemoryBackend is an in-memory backend useful for testing
/// single-node multi-process scenarios (shared via fork).
pub const SimpleMemoryBackend = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Entry),
    mutex: std.atomic.Mutex,

    const Entry = struct {
        value: []const u8,
        expires_at_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator) SimpleMemoryBackend {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
            .mutex = .unlocked,
        };
    }

    pub fn deinit(self: *SimpleMemoryBackend) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.map.deinit();
    }

    pub fn cacheBackend(self: *SimpleMemoryBackend) CacheBackend {
        return .{
            .get = getImpl,
            .set = setImpl,
            .delete = deleteImpl,
            .ctx = self,
        };
    }

    fn getImpl(ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const self = @as(*SimpleMemoryBackend, @ptrCast(@alignCast(ctx.?)));
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const entry = self.map.get(key) orelse return null;
        const now = nowMs();
        if (entry.expires_at_ms < now) return null;
        return try allocator.dupe(u8, entry.value);
    }

    fn setImpl(ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8, value: []const u8, ttl_ms: u32) !void {
        const self = @as(*SimpleMemoryBackend, @ptrCast(@alignCast(ctx.?)));
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        const gop = try self.map.getOrPut(k);
        if (gop.found_existing) {
            allocator.free(gop.key_ptr.*);
            allocator.free(gop.value_ptr.value);
            gop.key_ptr.* = k;
        }
        gop.value_ptr.* = .{
            .value = v,
            .expires_at_ms = nowMs() + @as(i64, ttl_ms),
        };
    }

    fn deleteImpl(ctx: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) !void {
        const self = @as(*SimpleMemoryBackend, @ptrCast(@alignCast(ctx.?)));
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.map.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value.value);
        }
    }

};

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "SimpleMemoryBackend get/set/delete" {
    var backend = SimpleMemoryBackend.init(std.testing.allocator);
    defer backend.deinit();
    const cb = backend.cacheBackend();

    // Miss
    const miss = try cb.get(cb.ctx, std.testing.allocator, "key1");
    try std.testing.expect(miss == null);

    // Set
    try cb.set(cb.ctx, std.testing.allocator, "key1", "hello", 10000);

    // Hit
    const hit = try cb.get(cb.ctx, std.testing.allocator, "key1");
    defer if (hit) |h| std.testing.allocator.free(h);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("hello", hit.?);

    // Delete
    try cb.delete(cb.ctx, std.testing.allocator, "key1");
    const after = try cb.get(cb.ctx, std.testing.allocator, "key1");
    try std.testing.expect(after == null);
}

test "DistributedCache L1+L2 roundtrip" {
    var l1 = ResponseCache.init(std.testing.allocator, 5000);
    defer l1.deinit();

    var backend = SimpleMemoryBackend.init(std.testing.allocator);
    defer backend.deinit();

    var dc = DistributedCache.init(
        std.testing.allocator,
        backend.cacheBackend(),
        try std.testing.allocator.dupe(u8, "test:"),
        &l1,
    );
    defer dc.deinit();

    const now: i64 = nowMs();

    // Miss
    const miss = try dc.get("query1", now);
    try std.testing.expect(miss == null);

    // Set
    try dc.set("query1", "{\"data\":{\"hello\":\"world\"}}", 10000, now);

    // L1 hit (immediate)
    const hit1 = try dc.get("query1", now);
    defer if (hit1) |h| std.testing.allocator.free(h);
    try std.testing.expect(hit1 != null);
    try std.testing.expectEqualStrings("{\"data\":{\"hello\":\"world\"}}", hit1.?);

    // Simulate L1 eviction by clearing l1 entries manually
    var iter = l1.entries.iterator();
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer {
        for (to_remove.items) |k| std.testing.allocator.free(k);
        to_remove.deinit(std.testing.allocator);
    }
    while (iter.next()) |entry| {
        try to_remove.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.key_ptr.*));
    }
    for (to_remove.items) |k| {
        if (l1.entries.fetchRemove(k)) |removed| {
            std.testing.allocator.free(removed.key);
            std.testing.allocator.free(removed.value.response);
        }
    }

    // L2 hit (backfills L1)
    const hit2 = try dc.get("query1", now);
    defer if (hit2) |h| std.testing.allocator.free(h);
    try std.testing.expect(hit2 != null);
    try std.testing.expectEqualStrings("{\"data\":{\"hello\":\"world\"}}", hit2.?);
}

test "DistributedCache setWithDefaultTtl" {
    var backend = SimpleMemoryBackend.init(std.testing.allocator);
    defer backend.deinit();

    var dc = DistributedCache.init(
        std.testing.allocator,
        backend.cacheBackend(),
        try std.testing.allocator.dupe(u8, "test:"),
        null,
    );
    defer dc.deinit();

    const now: i64 = nowMs();
    try dc.setWithDefaultTtl("q", "value", now);

    const hit = try dc.get("q", now);
    defer if (hit) |h| std.testing.allocator.free(h);
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("value", hit.?);
}
