const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("parser.zig").Parser;

/// Query Plan Cache — caches parsed AST Documents keyed by query hash.
///
/// Each cached document lives in its own arena allocator. When an entry is
/// evicted the entire arena is destroyed, so callers must not hold references
/// to cached documents across cache mutations.
///
/// Typical usage in the server pipeline:
///   1. Compute SHA-256 of the query string
///   2. Call `cache.get(hash, now_ms)` — if hit, skip parse
///   3. If miss, parse the query and `cache.put(hash, query, now_ms)`
///   4. Use the returned `*const ast.Document` for validation & execution
pub const QueryPlanCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    mutex: std.atomic.Mutex,
    ttl_ms: i64,

    const Entry = struct {
        arena: *std.heap.ArenaAllocator,
        document: ast.Document,
        expires_at_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator, ttl_ms: i64) QueryPlanCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
            .mutex = .unlocked,
            .ttl_ms = ttl_ms,
        };
    }

    pub fn deinit(self: *QueryPlanCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.arena.deinit();
            self.allocator.destroy(entry.value_ptr.arena);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// Look up a cached parsed document. Returns a borrowed reference.
    /// The reference is only valid while the entry remains in the cache.
    pub fn get(self: *QueryPlanCache, hash: []const u8, now_ms: i64) ?*const ast.Document {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const entry = self.entries.getPtr(hash) orelse return null;
        if (entry.expires_at_ms < now_ms) return null;
        return &entry.document;
    }

    /// Parse `query` and store the resulting AST under `hash`.
    pub fn put(self: *QueryPlanCache, hash: []const u8, query: []const u8, now_ms: i64) !void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, hash);
        errdefer self.allocator.free(key);

        const arena_ptr = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena_ptr.deinit();

        const arena_alloc = arena_ptr.allocator();
        var parser = try Parser.init(arena_alloc, query);
        const doc = try parser.parseDocument();

        const gop = try self.entries.getOrPut(key);
        if (gop.found_existing) {
            gop.value_ptr.arena.deinit();
            self.allocator.destroy(gop.value_ptr.arena);
            self.allocator.free(gop.key_ptr.*);
            gop.key_ptr.* = key;
        }

        gop.value_ptr.* = .{
            .arena = arena_ptr,
            .document = doc,
            .expires_at_ms = now_ms + self.ttl_ms,
        };
    }

    /// Remove expired entries. Call periodically (e.g. on a timer).
    pub fn prune(self: *QueryPlanCache, now_ms: i64) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var to_remove = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit();
        }

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.expires_at_ms < now_ms) {
                const key = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                to_remove.append(key) catch {
                    self.allocator.free(key);
                    continue;
                };
            }
        }

        for (to_remove.items) |k| {
            if (self.entries.fetchRemove(k)) |removed| {
                removed.value.arena.deinit();
                self.allocator.destroy(removed.value.arena);
                self.allocator.free(removed.key);
            }
        }
    }

    fn lockMutex(mutex: *std.atomic.Mutex) void {
        while (!mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }
};

test "QueryPlanCache basic" {
    const allocator = std.testing.allocator;

    var cache = QueryPlanCache.init(allocator, 1000);
    defer cache.deinit();

    const query = "query { hello }";
    const hash = "abc123";

    // Miss
    try std.testing.expect(cache.get(hash, 0) == null);

    // Store
    try cache.put(hash, query, 0);

    // Hit
    const doc = cache.get(hash, 0).?;
    try std.testing.expectEqual(@as(usize, 1), doc.definitions.items.len);

    // Expired
    try std.testing.expect(cache.get(hash, 2000) == null);
}

test "QueryPlanCache overwrite" {
    const allocator = std.testing.allocator;

    var cache = QueryPlanCache.init(allocator, 1000);
    defer cache.deinit();

    try cache.put("h1", "{ a }", 0);
    try cache.put("h1", "{ b }", 0);

    const doc = cache.get("h1", 0).?;
    const field_name = doc.definitions.items[0].operation.selection_set.selections.items[0].field.name;
    try std.testing.expectEqualStrings("b", field_name);
}
