/// Database Example
/// ============================================================================
/// This example demonstrates how to integrate a database with zgraphql:
///   - Pass a database handle via ExecutionContext.user_data
///   - Use DataLoader for N+1-safe batch queries
///   - Manage transactions in mutation resolvers
///
/// For demonstration purposes, a simple JSON Lines file is used as the
/// backing store (zero external dependencies). In production, replace
/// InMemoryDatabase with SQLite, PostgreSQL, or any real database client.
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
};

/// An in-memory "database" for demonstration.
/// In production, replace this with SQLite, PostgreSQL, or any real DB client.
const InMemoryDatabase = struct {
    allocator: std.mem.Allocator,
    data: std.AutoHashMap(i64, User),
    next_id: i64,
    // Transaction state
    tx_active: bool,
    tx_backup: std.AutoHashMap(i64, User),

    pub fn init(allocator: std.mem.Allocator) InMemoryDatabase {
        return .{
            .allocator = allocator,
            .data = std.AutoHashMap(i64, User).init(allocator),
            .next_id = 1,
            .tx_active = false,
            .tx_backup = std.AutoHashMap(i64, User).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryDatabase) void {
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.email);
        }
        self.data.deinit();

        var biter = self.tx_backup.iterator();
        while (biter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.email);
        }
        self.tx_backup.deinit();
    }

    pub fn getById(self: *InMemoryDatabase, id: i64) ?User {
        return self.data.get(id);
    }

    pub fn getManyById(self: *InMemoryDatabase, ids: []const i64, alloc: std.mem.Allocator) ![]?User {
        var results = try alloc.alloc(?User, ids.len);
        for (ids, 0..) |id, i| {
            results[i] = self.data.get(id);
        }
        return results;
    }

    pub fn getAll(self: *InMemoryDatabase, alloc: std.mem.Allocator) ![]User {
        var results = try alloc.alloc(User, self.data.count());
        var iter = self.data.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            results[i] = entry.value_ptr.*;
        }
        return results;
    }

    pub fn insert(self: *InMemoryDatabase, name: []const u8, email: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const email_copy = try self.allocator.dupe(u8, email);
        errdefer self.allocator.free(email_copy);
        try self.data.put(id, .{ .id = id, .name = name_copy, .email = email_copy });
        return id;
    }

    // Simple transaction support: backup data on begin, restore on rollback.
    pub fn beginTx(self: *InMemoryDatabase) !void {
        if (self.tx_active) return error.TxAlreadyActive;
        self.tx_active = true;
        self.tx_backup.clearRetainingCapacity();
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.value_ptr.name);
            errdefer self.allocator.free(name);
            const email = try self.allocator.dupe(u8, entry.value_ptr.email);
            errdefer self.allocator.free(email);
            try self.tx_backup.put(entry.key_ptr.*, .{
                .id = entry.key_ptr.*,
                .name = name,
                .email = email,
            });
        }
    }

    pub fn commitTx(self: *InMemoryDatabase) !void {
        if (!self.tx_active) return error.NoActiveTx;
        self.tx_active = false;
        // Clear backup (committed)
        var biter = self.tx_backup.iterator();
        while (biter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.email);
        }
        self.tx_backup.clearRetainingCapacity();
        // Transaction committed (no file persistence in this in-memory example)
    }

    pub fn rollbackTx(self: *InMemoryDatabase) !void {
        if (!self.tx_active) return error.NoActiveTx;
        self.tx_active = false;
        // Restore from backup
        var iter = self.data.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.email);
        }
        self.data.clearRetainingCapacity();
        var biter = self.tx_backup.iterator();
        while (biter.next()) |entry| {
            try self.data.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.tx_backup.clearRetainingCapacity();
    }
};

const AppContext = struct {
    db: *InMemoryDatabase,
    dl: *zg.DataLoader,
};

fn userResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const id = args.get("id").?.data.int;

    // Use DataLoader to enable batching / deduplication
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{d}", .{id});
    if (try app.dl.load(key)) |cached| {
        // load() already returns an owned clone; return it directly.
        return cached;
    }

    if (app.db.getById(id)) |u| {
        var obj = zg.Value.initObject(alloc);
        try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, u.id));
        try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.name)));
        try obj.data.object.put(try alloc.dupe(u8, "email"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.email)));
        return obj;
    }
    return zg.Value.fromNull(alloc);
}

fn usersResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const users = try app.db.getAll(alloc);
    defer alloc.free(users);

    var list = zg.Value.initList(alloc);
    for (users) |u| {
        var obj = zg.Value.initObject(alloc);
        try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, u.id));
        try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.name)));
        try obj.data.object.put(try alloc.dupe(u8, "email"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.email)));
        try list.data.list.append(obj);
    }
    return list;
}

fn createUserResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const name = args.get("name").?.data.string;
    const email = args.get("email").?.data.string;

    try app.db.beginTx();
    errdefer app.db.rollbackTx() catch {};

    const id = try app.db.insert(name, email);
    try app.db.commitTx();

    var obj = zg.Value.initObject(alloc);
    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, id));
    try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, name)));
    try obj.data.object.put(try alloc.dupe(u8, "email"), zg.Value.fromString(alloc, try alloc.dupe(u8, email)));
    return obj;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = InMemoryDatabase.init(allocator);
    defer db.deinit();

    // Seed initial data
    _ = try db.insert("Alice", "alice@example.com");
    _ = try db.insert("Bob", "bob@example.com");

    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .user = .{ .type = "User", .args = .{ .id = .{ .type = "ID!" } } },
            .users = .{ .type = "[User]" },
        },
        .Mutation = .{
            .createUser = .{ .type = "User", .args = .{ .name = .{ .type = "String!" }, .email = .{ .type = "String!" } } },
        },
        .User = .{
            .id = .{ .type = "ID!" },
            .name = .{ .type = "String!" },
            .email = .{ .type = "String!" },
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    if (schema_def.query_type.kind.object.fields.getPtr("user")) |field| {
        field.resolve = userResolver;
    }
    if (schema_def.query_type.kind.object.fields.getPtr("users")) |field| {
        field.resolve = usersResolver;
    }
    if (schema_def.mutation_type) |mt| {
        if (mt.kind.object.fields.getPtr("createUser")) |field| {
            field.resolve = createUserResolver;
        }
    }

    // Setup DataLoader for batch loading users by ID
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var io_backend = IoBackend.init(allocator, .{});
    defer io_backend.deinit();

    var dl = zg.DataLoader.init(allocator, io_backend.io());
    defer dl.deinit();

    var app_ctx = AppContext{
        .db = &db,
        .dl = &dl,
    };

    dl.setBatchLoader(struct {
        fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
            const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
            var ids = try alloc.alloc(i64, keys.len);
            defer alloc.free(ids);
            for (keys, 0..) |k, i| {
                ids[i] = try std.fmt.parseInt(i64, k, 10);
            }
            const results = try app.db.getManyById(ids, alloc);
            defer alloc.free(results);

            var values = try alloc.alloc(zg.Value, keys.len);
            for (results, 0..) |maybe_user, i| {
                if (maybe_user) |u| {
                    var obj = zg.Value.initObject(alloc);
                    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, u.id));
                    try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.name)));
                    try obj.data.object.put(try alloc.dupe(u8, "email"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.email)));
                    values[i] = obj;
                } else {
                    values[i] = zg.Value.fromNull(alloc);
                }
            }
            return values;
        }
    }.batch, &app_ctx);

    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 15,
        .user_data = &app_ctx,
    });

    std.debug.print("Database-backed GraphQL server on http://127.0.0.1:8080/graphql\n", .{});
    std.debug.print("Data file: users.jsonl\n", .{});
    std.debug.print("\nQuery:\n", .{});
    std.debug.print("  curl -X POST http://127.0.0.1:8080/graphql -H 'Content-Type: application/json' -d '{s}'\n", .{"{\"query\":\"{ users { id name email } }\"}"});
    std.debug.print("\nMutation:\n", .{});
    std.debug.print("  curl -X POST http://127.0.0.1:8080/graphql -H 'Content-Type: application/json' -d '{s}'\n", .{"{\"query\":\"mutation { createUser(name: \\\"Charlie\\\" email: \\\"charlie@example.com\\\") { id name email } }\"}"});

    try server.listen(io_backend.io());
}
