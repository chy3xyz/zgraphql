/// ============================================================================
/// DataLoader Example / DataLoader 示例
/// ============================================================================
/// This example demonstrates the N+1 problem solution using DataLoader.
/// DataLoader batches and deduplicates multiple individual loads into a
/// single batch function call, dramatically reducing database round-trips.
///
/// 本示例演示了使用 DataLoader 解决 N+1 问题。
/// DataLoader 将多个独立的加载请求批量化和去重，合并为单次批量函数调用，
/// 显著减少数据库往返次数。
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

/// Simulated database / 模拟数据库
const FakeDb = struct {
    /// How many batch queries were executed / 执行了多少次批量查询
    query_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Batch fetch users by IDs / 按 ID 批量获取用户
    fn fetchUsers(db: *FakeDb, alloc: std.mem.Allocator, ids: []const []const u8) ![]zg.Value {
        _ = db.query_count.fetchAdd(1, .seq_cst);

        var results = try alloc.alloc(zg.Value, ids.len);
        for (ids, 0..) |id, i| {
            // In real code: SELECT * FROM users WHERE id IN (...)
            // 真实代码：SELECT * FROM users WHERE id IN (...)
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

    // Create DataLoader with a batch function / 创建 DataLoader 并设置批量函数
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
    //
    // 模拟在单个 GraphQL 查询中解析多个用户字段。
    // 没有 DataLoader 时，这会触发 N 次独立的数据库查询。
    // 使用 DataLoader，所有加载都被合并为一次数据库调用。
    const user_ids = &.{ "1", "2", "3", "4", "5" };

    std.debug.print("Loading {d} users...\n", .{user_ids.len});
    const users = try dl.loadMany(user_ids);

    std.debug.print("Results:\n", .{});
    for (users, 0..) |user, i| {
        const id = user.data.object.get("id").?.data.string;
        const name = user.data.object.get("name").?.data.string;
        std.debug.print("  [{d}] id={s}, name={s}\n", .{ i, id, name });
    }

    // Load the same key again - it hits the cache, no DB call.
    // 再次加载相同的 key - 命中缓存，无数据库调用。
    const cached = dl.load("1");
    std.debug.print("\nCache hit for '1': {s}\n", .{if (cached != null) "yes" else "no"});

    // Second batch load / 第二次批量加载
    const more_ids = &.{ "1", "3", "6" };
    std.debug.print("\nLoading {d} more users (some already cached)...\n", .{more_ids.len});
    const more = try dl.loadMany(more_ids);
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
