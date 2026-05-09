const std = @import("std");

/// Simple in-memory response cache for GraphQL query results.
/// Keys are query strings; values are JSON response strings with TTL.
/// Thread-safe via a spinlock.
///
/// Best suited for cacheable queries (no variables, no mutations).
pub const ResponseCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    mutex: std.atomic.Mutex,
    default_ttl_ms: i64,

    const Entry = struct {
        response: []const u8,
        expires_at_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator, default_ttl_ms: i64) ResponseCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
            .mutex = .unlocked,
            .default_ttl_ms = default_ttl_ms,
        };
    }

    pub fn deinit(self: *ResponseCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.response);
        }
        self.entries.deinit();
    }

    fn lockMutex(mutex: *std.atomic.Mutex) void {
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    /// Look up a cached response. Returns null if missing or expired.
    pub fn get(self: *ResponseCache, key: []const u8, now_ms: i64) ?[]const u8 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const entry = self.entries.get(key) orelse return null;
        if (entry.expires_at_ms < now_ms) return null;
        return entry.response;
    }

    /// Store a response in the cache. If the key already exists, the old entry is replaced.
    pub fn put(self: *ResponseCache, key: []const u8, response: []const u8, now_ms: i64) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const response_copy = try self.allocator.dupe(u8, response);
        errdefer self.allocator.free(response_copy);

        const gop = try self.entries.getOrPut(key_copy);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.response);
            gop.key_ptr.* = key_copy;
        }
        gop.value_ptr.* = .{
            .response = response_copy,
            .expires_at_ms = now_ms + self.default_ttl_ms,
        };
    }

    /// Remove expired entries. Call periodically (e.g. on a timer).
    pub fn prune(self: *ResponseCache, now_ms: i64) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var iter = self.entries.iterator();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit();
        }

        while (iter.next()) |entry| {
            if (entry.value_ptr.expires_at_ms < now_ms) {
                to_remove.append(try self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
            }
        }

        for (to_remove.items) |k| {
            if (self.entries.fetchRemove(k)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.response);
            }
        }
    }
};

test "ResponseCache basic" {
    const allocator = std.testing.allocator;
    var cache = ResponseCache.init(allocator, 1000);
    defer cache.deinit();

    try cache.put("query1", "{\"data\":{}}", 0);
    try std.testing.expectEqualStrings("{\"data\":{}}", cache.get("query1", 0).?);
    try std.testing.expect(cache.get("query1", 2000) == null); // expired
}
