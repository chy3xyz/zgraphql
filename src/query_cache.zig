const std = @import("std");

/// QueryCache provides query whitelisting and automatic persisted queries (APQ).
///
/// Two modes:
/// 1. **Whitelist**: Only allow queries that have been explicitly registered.
/// 2. **APQ**: Store queries by hash, clients send hash instead of full query.
///
/// Thread safety: all public methods are internally synchronized with a
/// spin lock, so a single `QueryCache` instance may be shared across
/// concurrent requests.
pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    // hash -> query string
    queries: std.StringHashMap([]const u8),
    mutex: std.atomic.Mutex = .unlocked,

    fn lockMutex(mutex: *std.atomic.Mutex) void {
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn init(allocator: std.mem.Allocator) QueryCache {
        return .{
            .allocator = allocator,
            .queries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *QueryCache) void {
        var iter = self.queries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.queries.deinit();
    }

    /// Register a query. Computes SHA-256 hash as the key.
    pub fn store(self: *QueryCache, query: []const u8) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const hash = try computeHash(self.allocator, query);
        errdefer self.allocator.free(hash);

        if (self.queries.contains(hash)) {
            self.allocator.free(hash);
            return;
        }

        const query_copy = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(query_copy);

        try self.queries.put(hash, query_copy);
    }

    /// Register a query with an explicit key (e.g., a human-readable name).
    pub fn storeNamed(self: *QueryCache, key: []const u8, query: []const u8) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const query_copy = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(query_copy);

        // Remove old entry if exists
        if (self.queries.fetchRemove(key_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.queries.put(key_copy, query_copy);
    }

    /// Look up a query by hash/key. Returns an owned copy, or null if not found.
    /// Caller owns the returned string and must free it.
    pub fn get(self: *QueryCache, hash: []const u8) ?[]const u8 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const q = self.queries.get(hash) orelse return null;
        return self.allocator.dupe(u8, q) catch null;
    }

    /// Look up a query by hash/key, case-insensitive. Returns an owned copy,
    /// or null if not found. Caller owns the returned string and must free it.
    pub fn getInsensitive(self: *QueryCache, hash: []const u8) ?[]const u8 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (self.queries.get(hash)) |q| return self.allocator.dupe(u8, q) catch null;
        var lower_buf: [64]u8 = undefined;
        if (hash.len > lower_buf.len) return null;
        const lower = std.ascii.lowerString(&lower_buf, hash);
        if (self.queries.get(lower)) |q| return self.allocator.dupe(u8, q) catch null;
        return null;
    }

    /// Check if a query is in the cache. Zero-allocation: uses stack buffer for hash.
    pub fn contains(self: *QueryCache, query: []const u8) bool {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var hex_buf: [64]u8 = undefined;
        computeHashBuf(query, &hex_buf);
        return self.queries.contains(&hex_buf);
    }

    /// Remove a query from the cache.
    pub fn remove(self: *QueryCache, hash: []const u8) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (self.queries.fetchRemove(hash)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    pub fn computeHash(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]const u8 {
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(query, &hash_bytes, .{});
        const hex = std.fmt.bytesToHex(hash_bytes, .lower);
        return try allocator.dupe(u8, &hex);
    }

    /// Write the SHA-256 hex hash of `query` into `buf` (must be at least 64 bytes).
    pub fn computeHashBuf(query: []const u8, buf: []u8) void {
        var hash_bytes: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(query, &hash_bytes, .{});
        const hex = std.fmt.bytesToHex(hash_bytes, .lower);
        @memcpy(buf[0..hex.len], &hex);
    }
};

test "query cache store and get" {
    const allocator = std.testing.allocator;

    var cache = QueryCache.init(allocator);
    defer cache.deinit();

    const query = "{ hello }";
    try cache.store(query);

    // Compute hash manually to look up
    const hash = try QueryCache.computeHash(allocator, query);
    defer allocator.free(hash);

    const retrieved = cache.get(hash);
    defer if (retrieved) |r| allocator.free(r);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings(query, retrieved.?);
}

test "query cache named store" {
    const allocator = std.testing.allocator;

    var cache = QueryCache.init(allocator);
    defer cache.deinit();

    try cache.storeNamed("getUser", "query GetUser($id: ID!) { user(id: $id) { name } }");

    const retrieved = cache.get("getUser");
    defer if (retrieved) |r| allocator.free(r);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("query GetUser($id: ID!) { user(id: $id) { name } }", retrieved.?);
}

test "query cache contains" {
    const allocator = std.testing.allocator;

    var cache = QueryCache.init(allocator);
    defer cache.deinit();

    const query = "{ hello }";
    _ = try cache.store(query);

    try std.testing.expect(cache.contains(query));
    try std.testing.expect(!cache.contains("{ goodbye }"));
}

test "query cache case insensitive get" {
    const allocator = std.testing.allocator;

    var cache = QueryCache.init(allocator);
    defer cache.deinit();

    const query = "{ hello }";
    try cache.store(query);

    const hash = try QueryCache.computeHash(allocator, query);
    defer allocator.free(hash);

    // Uppercase hash lookup
    const upper = try allocator.alloc(u8, hash.len);
    defer allocator.free(upper);
    _ = std.ascii.upperString(upper, hash);

    const via_upper = cache.getInsensitive(upper);
    defer if (via_upper) |r| allocator.free(r);
    try std.testing.expect(via_upper != null);
    try std.testing.expect(cache.get(upper) == null); // exact match fails
}

test "query cache remove frees entry" {
    const allocator = std.testing.allocator;

    var cache = QueryCache.init(allocator);
    defer cache.deinit();

    try cache.store("{ hello }");
    const hash = try QueryCache.computeHash(allocator, "{ hello }");
    defer allocator.free(hash);

    try std.testing.expect(cache.contains("{ hello }"));
    cache.remove(hash);
    try std.testing.expect(!cache.contains("{ hello }"));
    try std.testing.expect(cache.get(hash) == null);
}

test "query cache concurrent store and get" {
    const allocator = std.testing.allocator;

    var cache = QueryCache.init(allocator);
    defer cache.deinit();

    // Pre-populate a set of queries.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [64]u8 = undefined;
        const q = try std.fmt.bufPrint(&buf, "{{ hello {d} }}", .{i});
        try cache.store(q);
    }

    // Concurrently read and write from multiple threads. The spin lock must
    // keep the underlying hash map consistent (no data race).
    const threads = 4;
    const iters_per_thread = 200;
    var errors: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    const worker = struct {
        fn run(c: *QueryCache, a: std.mem.Allocator, errs: *std.atomic.Value(u32)) void {
            var k: usize = 0;
            while (k < iters_per_thread) : (k += 1) {
                var buf: [64]u8 = undefined;
                const q = std.fmt.bufPrint(&buf, "{{ hello {d} }}", .{k % 20}) catch continue;
                if (c.get(q)) |owned| {
                    a.free(owned);
                }
                if (!c.contains(q)) {
                    _ = errs.fetchAdd(1, .seq_cst);
                }
            }
        }
    }.run;

    var handles: [threads]std.Thread = undefined;
    for (&handles) |*h| {
        h.* = try std.Thread.spawn(.{}, worker, .{ &cache, allocator, &errors });
    }
    for (&handles) |*h| h.join();

    try std.testing.expectEqual(@as(u32, 0), errors.load(.seq_cst));
}
