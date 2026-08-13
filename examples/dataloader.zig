/// DataLoader Example
/// ============================================================================
/// This example demonstrates the N+1 problem solution using DataLoader.
/// DataLoader batches and deduplicates multiple individual loads into a
/// single batch function call, dramatically reducing database round-trips.
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

/// Simulated database
const FakeDb = struct {
    /// How many batch queries were executed
    query_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Batch fetch users by IDs
    fn fetchUsers(db: *FakeDb, alloc: std.mem.Allocator, ids: []const []const u8) ![]zg.Value {
        _ = db.query_count.fetchAdd(1, .seq_cst);

        var results = try alloc.alloc(zg.Value, ids.len);
        for (ids, 0..) |id, i| {
            // In real code: SELECT * FROM users WHERE id IN (...)
            var user = zg.Value.initObject(alloc);
            try user.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromString(alloc, try alloc.dupe(u8, id)));
            try user.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try std.fmt.allocPrint(alloc, "User_{s}", .{id})));
            results[i] = user;
        }
        return results;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = FakeDb{};

    // Create DataLoader with a batch function
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var dl = zg.DataLoader.init(allocator, backend.io());
    defer dl.deinit();

    dl.setBatchLoader(struct {
        fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
            const d = @as(*FakeDb, @ptrCast(@alignCast(ctx.?)));
            return d.fetchUsers(alloc, keys);
        }
    }.batch, &db);

    // Simulate resolving multiple user fields in a single GraphQL query.
    // Without DataLoader, this would trigger N separate DB queries.
    // With DataLoader, all loads are batched into a single DB call.
    const user_ids = &.{ "1", "2", "3", "4", "5" };

    std.debug.print("Loading {d} users...\n", .{user_ids.len});
    const users = try dl.loadMany(user_ids);
    defer {
        for (users) |*user| user.deinit(allocator);
        allocator.free(users);
    }

    std.debug.print("Results:\n", .{});
    for (users, 0..) |user, i| {
        const id = user.data.object.get("id").?.data.string;
        const name = user.data.object.get("name").?.data.string;
        std.debug.print("  [{d}] id={s}, name={s}\n", .{ i, id, name });
    }

    // Load the same key again - it hits the cache, no DB call.
    const cached = try dl.load("1");
    defer if (cached) |c| {
        var owned = c;
        owned.deinit(allocator);
    };
    std.debug.print("\nCache hit for '1': {s}\n", .{if (cached != null) "yes" else "no"});

    // Second batch load
    const more_ids = &.{ "1", "3", "6" };
    std.debug.print("\nLoading {d} more users (some already cached)...\n", .{more_ids.len});
    const more = try dl.loadMany(more_ids);
    defer {
        for (more) |*user| user.deinit(allocator);
        allocator.free(more);
    }
    for (more, 0..) |user, i| {
        const id = user.data.object.get("id").?.data.string;
        const name = user.data.object.get("name").?.data.string;
        std.debug.print("  [{d}] id={s}, name={s}\n", .{ i, id, name });
    }

    const query_count = db.query_count.load(.seq_cst);
    std.debug.print("\nTotal DB batch queries executed: {d}\n", .{query_count});
    std.debug.print("Without DataLoader this would have been: {d}\n", .{user_ids.len + more_ids.len});
    std.debug.print("Savings: {d}% fewer DB round-trips\n", .{
        100 - @divTrunc(query_count * 100, user_ids.len + more_ids.len),
    });
}
