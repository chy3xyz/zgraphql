const std = @import("std");
const Value = @import("value.zig").Value;

/// DataLoader provides request-level caching and batch loading to solve the N+1 query problem.
///
/// Usage patterns:
///
/// 1. **Pre-fetch (recommended):** Before executing a query, analyze it to identify
///    all data needs, fetch in batches, and prime the cache. Resolvers then hit cache.
///
/// 2. **Manual batching:** Resolvers call `load()` which checks cache. Cache misses
///    are collected and resolved via `flush()`.
///
/// 3. **Auto-batching (experimental):** `loadBatched()` uses `Io.sleep(0)` to yield
///    and allow concurrent fibers to queue their keys before flushing.
///
pub const DataLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: std.StringHashMap(Value),
    mutex: std.Io.Mutex = .init,

    /// Pending keys for batch loading. Only populated between `loadBatched` calls.
    pending: std.StringHashMap(void),

    /// Optional batch function. Signature: fn(ctx, allocator, keys) ![]Value
    batch_fn: ?*const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) anyerror![]Value = null,
    batch_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) DataLoader {
        return .{
            .allocator = allocator,
            .io = io,
            .cache = std.StringHashMap(Value).init(allocator),
            .pending = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *DataLoader) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.deinit();

        var piter = self.pending.keyIterator();
        while (piter.next()) |k| {
            self.allocator.free(k.*);
        }
        self.pending.deinit();
    }

    /// Set the batch loading function and context.
    pub fn setBatchLoader(
        self: *DataLoader,
        batch_fn: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) anyerror![]Value,
        batch_ctx: ?*anyopaque,
    ) void {
        self.batch_fn = batch_fn;
        self.batch_ctx = batch_ctx;
    }

    /// Check cache for a key. Returns a cloned value or null.
    pub fn load(self: *DataLoader, key: []const u8) ?Value {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);

        if (self.cache.get(key)) |v| {
            return v.clone() catch null;
        }
        return null;
    }

    /// Store a value in cache. The value is cloned; caller retains ownership.
    pub fn prime(self: *DataLoader, key: []const u8, value: Value) !void {
        self.mutex.lock(self.io) catch |err| return err;
        defer self.mutex.unlock(self.io);

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        var owned_value = try value.clone();
        errdefer owned_value.deinit();

        // Remove old entry if exists
        const removed = self.cache.fetchRemove(key);
        if (removed) |old| {
            self.allocator.free(old.key);
            var val = old.value;
            val.deinit();
        }

        try self.cache.put(owned_key, owned_value);
    }

    /// Load multiple keys via the batch function. Results are cached.
    /// Returns an array of values aligned with `keys`. Caller owns the returned slice.
    pub fn loadMany(self: *DataLoader, keys: []const []const u8) ![]Value {
        const batch_fn = self.batch_fn orelse return error.NoBatchFunction;

        // First pass: check cache under lock
        self.mutex.lock(self.io) catch |err| return err;
        defer self.mutex.unlock(self.io);

        var uncached = std.array_list.Managed([]const u8).init(self.allocator);
        defer uncached.deinit();

        for (keys) |k| {
            if (!self.cache.contains(k)) {
                try uncached.append(k);
            }
        }

        // Batch load uncached keys
        if (uncached.items.len > 0) {
            const values = try batch_fn(self.batch_ctx, self.allocator, uncached.items);
            defer {
                for (values) |*v| v.deinit();
                self.allocator.free(values);
            }

            if (values.len != uncached.items.len) return error.BatchResultMismatch;

            for (uncached.items, values) |k, v| {
                const owned_key = try self.allocator.dupe(u8, k);
                errdefer self.allocator.free(owned_key);
                var owned_value = try v.clone();
                errdefer owned_value.deinit();
                try self.cache.put(owned_key, owned_value);
            }
        }

        // Build result
        var result = try self.allocator.alloc(Value, keys.len);
        errdefer {
            for (result) |*v| v.deinit();
            self.allocator.free(result);
        }

        for (keys, 0..) |k, i| {
            result[i] = try self.cache.get(k).?.clone();
        }

        return result;
    }

    /// Auto-batched load. Best-effort batching using `Io.sleep(0)` to yield
    /// and allow concurrent fibers to queue keys.
    ///
    /// Returns error.NoBatchFunction if no batch function is configured.
    /// Returns error.BatchLoadFailed if the key could not be resolved.
    pub fn loadBatched(self: *DataLoader, key: []const u8) !(error{ NoBatchFunction, BatchLoadFailed, Canceled } || std.mem.Allocator.Error)!Value {
        // Fast path: already cached
        if (self.load(key)) |v| return v;

        const batch_fn = self.batch_fn orelse return error.NoBatchFunction;

        // Queue key
        {
            self.mutex.lock(self.io) catch |err| return err;
            defer self.mutex.unlock(self.io);
            try self.pending.put(try self.allocator.dupe(u8, key), {});
        }

        // Yield to allow concurrent fibers to queue their keys.
        // On most Io backends, sleep(0) will yield the fiber.
        std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(0), .monotonic) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
        };

        // Attempt flush under lock
        {
            self.mutex.lock(self.io) catch |err| return err;
            defer self.mutex.unlock(self.io);

            if (self.pending.count() > 0) {
                var keys_list = std.ArrayList([]const u8).init(self.allocator);
                defer {
                    for (keys_list.items) |k| self.allocator.free(k);
                    keys_list.deinit();
                }

                var iter = self.pending.keyIterator();
                while (iter.next()) |k| {
                    try keys_list.append(try self.allocator.dupe(u8, k.*));
                }

                const values = try batch_fn(self.batch_ctx, self.allocator, keys_list.items);
                defer self.allocator.free(values);

                if (values.len != keys_list.items.len) return error.BatchLoadFailed;

                for (keys_list.items, values) |k, v| {
                    const owned_key = try self.allocator.dupe(u8, k);
                    errdefer self.allocator.free(owned_key);
                    const owned_value = try v.clone();
                    errdefer owned_value.deinit();
                    try self.cache.put(owned_key, owned_value);
                }

                // Clear pending without freeing keys (they're now in cache)
                var piter = self.pending.keyIterator();
                while (piter.next()) |k| {
                    self.allocator.free(k.*);
                }
                self.pending.clearRetainingCapacity();
            }
        }

        if (self.load(key)) |v| return v;
        return error.BatchLoadFailed;
    }

    /// Clear all cached entries.
    pub fn clear(self: *DataLoader) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.clearRetainingCapacity();
    }
};

test "dataloader cache" {
    const allocator = std.testing.allocator;
    // Use a placeholder Io since cache operations don't need real I/O
    const io: std.Io = undefined;

    var dl = DataLoader.init(allocator, io);
    defer dl.deinit();

    // Prime cache
    var val = Value.fromString(allocator, try allocator.dupe(u8, "hello"));
    defer val.deinit();
    try dl.prime("key1", val);

    // Load from cache
    var loaded = dl.load("key1").?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("hello", loaded.data.string);

    // Missing key
    try std.testing.expect(dl.load("missing") == null);
}

test "dataloader loadMany" {
    const allocator = std.testing.allocator;
    const io: std.Io = undefined;

    var dl = DataLoader.init(allocator, io);
    defer dl.deinit();

    var call_count: usize = 0;
    const Ctx = struct {
        count: *usize,
        fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) anyerror![]Value {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            self.count.* += 1;
            var result = try alloc.alloc(Value, keys.len);
            for (keys, 0..) |k, i| {
                result[i] = Value.fromString(alloc, try alloc.dupe(u8, k));
            }
            return result;
        }
    };
    var ctx = Ctx{ .count = &call_count };

    dl.setBatchLoader(Ctx.batch, &ctx);

    // First loadMany - should call batch
    const keys = &[_][]const u8{ "a", "b", "c" };
    const values = try dl.loadMany(keys);
    defer {
        for (values) |*v| v.deinit();
        allocator.free(values);
    }

    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqualStrings("a", values[0].data.string);
    try std.testing.expectEqualStrings("b", values[1].data.string);
    try std.testing.expectEqualStrings("c", values[2].data.string);

    // Second loadMany with same keys - should NOT call batch (cached)
    const values2 = try dl.loadMany(keys);
    defer {
        for (values2) |*v| v.deinit();
        allocator.free(values2);
    }

    try std.testing.expectEqual(@as(usize, 1), call_count);
}
