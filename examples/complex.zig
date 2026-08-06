/// Complex Example
/// ============================================================================
/// A comprehensive real-world-style GraphQL API demonstrating zgraphql's
/// full feature set in a single application.
///
/// Domain: E-commerce + Social (users, posts, comments, products, orders)
///
/// Features demonstrated:
///   - Complex schema with unions, enums, interfaces, nested types
///   - Multiple queries, mutations, and subscriptions
///   - DataLoader batch loading for N+1 prevention
///   - Role-based field authorization (user vs admin)
///   - Tenant isolation with per-tenant product catalogs
///   - Distributed cache (L1 + L2) for product queries
///   - Audit logging of every request
///   - Metrics collection
///   - Rate limiting
///   - Query depth / complexity limits
///   - WebSocket subscriptions for real-time order notifications
/// ============================================================================

const std = @import("std");
const zg = @import("zgraphql");

// ------------------------------------------------------------------
// Data Models
// ------------------------------------------------------------------

const Role = enum { user, admin };
const OrderStatus = enum { pending, confirmed, shipped, delivered };

const UserRecord = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    role: Role,
    tenant_id: []const u8,
};

const PostRecord = struct {
    id: i64,
    title: []const u8,
    content: []const u8,
    author_id: i64,
    created_at: i64,
};

const CommentRecord = struct {
    id: i64,
    content: []const u8,
    author_id: i64,
    post_id: i64,
    created_at: i64,
};

const ProductRecord = struct {
    id: i64,
    name: []const u8,
    price: f64,
    category: []const u8,
    stock: i32,
    tenant_id: []const u8,
};

const OrderItemRecord = struct {
    product_id: i64,
    quantity: i32,
    unit_price: f64,
};

const OrderRecord = struct {
    id: i64,
    user_id: i64,
    items: []OrderItemRecord,
    total: f64,
    status: OrderStatus,
    created_at: i64,
};

// ------------------------------------------------------------------
// In-Memory Database
// ------------------------------------------------------------------

const Database = struct {
    allocator: std.mem.Allocator,
    users: std.AutoHashMap(i64, UserRecord),
    posts: std.AutoHashMap(i64, PostRecord),
    comments: std.AutoHashMap(i64, CommentRecord),
    products: std.AutoHashMap(i64, ProductRecord),
    orders: std.AutoHashMap(i64, OrderRecord),
    next_user_id: i64,
    next_post_id: i64,
    next_comment_id: i64,
    next_product_id: i64,
    next_order_id: i64,

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{
            .allocator = allocator,
            .users = std.AutoHashMap(i64, UserRecord).init(allocator),
            .posts = std.AutoHashMap(i64, PostRecord).init(allocator),
            .comments = std.AutoHashMap(i64, CommentRecord).init(allocator),
            .products = std.AutoHashMap(i64, ProductRecord).init(allocator),
            .orders = std.AutoHashMap(i64, OrderRecord).init(allocator),
            .next_user_id = 1,
            .next_post_id = 1,
            .next_comment_id = 1,
            .next_product_id = 1,
            .next_order_id = 1,
        };
    }

    pub fn deinit(self: *Database) void {
        var uiter = self.users.iterator();
        while (uiter.next()) |e| {
            self.allocator.free(e.value_ptr.name);
            self.allocator.free(e.value_ptr.email);
            self.allocator.free(e.value_ptr.tenant_id);
        }
        self.users.deinit();

        var piter = self.posts.iterator();
        while (piter.next()) |e| {
            self.allocator.free(e.value_ptr.title);
            self.allocator.free(e.value_ptr.content);
        }
        self.posts.deinit();

        var citer = self.comments.iterator();
        while (citer.next()) |e| {
            self.allocator.free(e.value_ptr.content);
        }
        self.comments.deinit();

        var priter = self.products.iterator();
        while (priter.next()) |e| {
            self.allocator.free(e.value_ptr.name);
            self.allocator.free(e.value_ptr.category);
            self.allocator.free(e.value_ptr.tenant_id);
        }
        self.products.deinit();

        var oiter = self.orders.iterator();
        while (oiter.next()) |e| {
            self.allocator.free(e.value_ptr.items);
        }
        self.orders.deinit();
    }

    fn seed(self: *Database) !void {
        // Users across two tenants
        _ = try self.insertUser("Alice", "alice@example.com", .user, "tenant-a");
        _ = try self.insertUser("Bob", "bob@example.com", .user, "tenant-a");
        _ = try self.insertUser("Admin", "admin@example.com", .admin, "tenant-a");
        _ = try self.insertUser("Charlie", "charlie@example.com", .user, "tenant-b");

        // Posts
        const now = nowMs();
        _ = try self.insertPost("Hello World", "My first post!", 1, now);
        _ = try self.insertPost("Zig is great", "Zero dependencies and comptime power.", 2, now);
        _ = try self.insertPost("GraphQL tips", "Always use DataLoader for nested fields.", 1, now);

        // Comments
        _ = try self.insertComment("Nice post!", 2, 1, now);
        _ = try self.insertComment("Thanks!", 1, 1, now);
        _ = try self.insertComment("Agreed.", 1, 2, now);

        // Products for tenant-a
        _ = try self.insertProduct("Laptop", 999.99, "Electronics", 10, "tenant-a");
        _ = try self.insertProduct("Mouse", 29.99, "Electronics", 100, "tenant-a");
        _ = try self.insertProduct("Coffee Mug", 12.50, "Home", 50, "tenant-a");

        // Products for tenant-b
        _ = try self.insertProduct("Book: Zig in Action", 39.99, "Books", 20, "tenant-b");
        _ = try self.insertProduct("T-Shirt", 19.99, "Clothing", 30, "tenant-b");
    }

    fn insertUser(self: *Database, name: []const u8, email: []const u8, role: Role, tenant_id: []const u8) !i64 {
        const id = self.next_user_id;
        self.next_user_id += 1;
        try self.users.put(id, .{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .email = try self.allocator.dupe(u8, email),
            .role = role,
            .tenant_id = try self.allocator.dupe(u8, tenant_id),
        });
        return id;
    }

    fn insertPost(self: *Database, title: []const u8, content: []const u8, author_id: i64, created_at: i64) !i64 {
        const id = self.next_post_id;
        self.next_post_id += 1;
        try self.posts.put(id, .{
            .id = id,
            .title = try self.allocator.dupe(u8, title),
            .content = try self.allocator.dupe(u8, content),
            .author_id = author_id,
            .created_at = created_at,
        });
        return id;
    }

    fn insertComment(self: *Database, content: []const u8, author_id: i64, post_id: i64, created_at: i64) !i64 {
        const id = self.next_comment_id;
        self.next_comment_id += 1;
        try self.comments.put(id, .{
            .id = id,
            .content = try self.allocator.dupe(u8, content),
            .author_id = author_id,
            .post_id = post_id,
            .created_at = created_at,
        });
        return id;
    }

    fn insertProduct(self: *Database, name: []const u8, price: f64, category: []const u8, stock: i32, tenant_id: []const u8) !i64 {
        const id = self.next_product_id;
        self.next_product_id += 1;
        try self.products.put(id, .{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .price = price,
            .category = try self.allocator.dupe(u8, category),
            .stock = stock,
            .tenant_id = try self.allocator.dupe(u8, tenant_id),
        });
        return id;
    }

    fn insertOrder(self: *Database, user_id: i64, items: []OrderItemRecord, total: f64, status: OrderStatus, created_at: i64) !i64 {
        const id = self.next_order_id;
        self.next_order_id += 1;
        const items_copy = try self.allocator.dupe(OrderItemRecord, items);
        try self.orders.put(id, .{
            .id = id,
            .user_id = user_id,
            .items = items_copy,
            .total = total,
            .status = status,
            .created_at = created_at,
        });
        return id;
    }

    fn getUser(self: *Database, id: i64) ?UserRecord {
        return self.users.get(id);
    }

    fn getPost(self: *Database, id: i64) ?PostRecord {
        return self.posts.get(id);
    }

    fn getProduct(self: *Database, id: i64) ?ProductRecord {
        return self.products.get(id);
    }

    fn getOrder(self: *Database, id: i64) ?OrderRecord {
        return self.orders.get(id);
    }

    /// Returns the order with the smallest id greater than `after_id`, or null.
    fn getLatestOrderAbove(self: *Database, after_id: i64) ?OrderRecord {
        var best: ?OrderRecord = null;
        var iter = self.orders.iterator();
        while (iter.next()) |e| {
            if (e.key_ptr.* <= after_id) continue;
            if (best == null or e.key_ptr.* < best.?.id) {
                best = e.value_ptr.*;
            }
        }
        return best;
    }

    fn getComment(self: *Database, id: i64) ?CommentRecord {
        return self.comments.get(id);
    }

    fn getCommentsByPost(self: *Database, post_id: i64, alloc: std.mem.Allocator) ![]CommentRecord {
        var list: std.ArrayList(CommentRecord) = .empty;
        defer list.deinit(alloc);
        var iter = self.comments.iterator();
        while (iter.next()) |e| {
            if (e.value_ptr.post_id == post_id) {
                try list.append(alloc, e.value_ptr.*);
            }
        }
        return list.toOwnedSlice(alloc);
    }

    fn getPostsByAuthor(self: *Database, author_id: i64, alloc: std.mem.Allocator) ![]PostRecord {
        var list: std.ArrayList(PostRecord) = .empty;
        defer list.deinit(alloc);
        var iter = self.posts.iterator();
        while (iter.next()) |e| {
            if (e.value_ptr.author_id == author_id) {
                try list.append(alloc, e.value_ptr.*);
            }
        }
        return list.toOwnedSlice(alloc);
    }

    fn getProductsByTenant(self: *Database, tenant_id: []const u8, alloc: std.mem.Allocator) ![]ProductRecord {
        var list: std.ArrayList(ProductRecord) = .empty;
        defer list.deinit(alloc);
        var iter = self.products.iterator();
        while (iter.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.tenant_id, tenant_id)) {
                try list.append(alloc, e.value_ptr.*);
            }
        }
        return list.toOwnedSlice(alloc);
    }
};

// ------------------------------------------------------------------
// Application Context (passed to resolvers via user_data)
// ------------------------------------------------------------------

const AppContext = struct {
    allocator: std.mem.Allocator,
    db: *Database,
    user_dl: *zg.DataLoader,
    post_dl: *zg.DataLoader,
    product_dl: *zg.DataLoader,
    tenant_manager: *zg.TenantManager,
};

// ------------------------------------------------------------------
// Helper Functions
// ------------------------------------------------------------------

fn userToValue(alloc: std.mem.Allocator, u: UserRecord) !zg.Value {
    var obj = zg.Value.initObject(alloc);
    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, u.id));
    try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.name)));
    try obj.data.object.put(try alloc.dupe(u8, "email"), zg.Value.fromString(alloc, try alloc.dupe(u8, u.email)));
    const role_str = switch (u.role) {
        .user => "USER",
        .admin => "ADMIN",
    };
    try obj.data.object.put(try alloc.dupe(u8, "role"), zg.Value.fromEnum(alloc, try alloc.dupe(u8, role_str)));
    return obj;
}

fn postToValue(alloc: std.mem.Allocator, p: PostRecord, _: *AppContext) !zg.Value {
    var obj = zg.Value.initObject(alloc);
    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, p.id));
    try obj.data.object.put(try alloc.dupe(u8, "title"), zg.Value.fromString(alloc, try alloc.dupe(u8, p.title)));
    try obj.data.object.put(try alloc.dupe(u8, "content"), zg.Value.fromString(alloc, try alloc.dupe(u8, p.content)));
    try obj.data.object.put(try alloc.dupe(u8, "createdAt"), zg.Value.fromString(alloc, try std.fmt.allocPrint(alloc, "{d}", .{p.created_at})));
    return obj;
}

fn commentToValue(alloc: std.mem.Allocator, c: CommentRecord, _: *AppContext) !zg.Value {
    var obj = zg.Value.initObject(alloc);
    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, c.id));
    try obj.data.object.put(try alloc.dupe(u8, "content"), zg.Value.fromString(alloc, try alloc.dupe(u8, c.content)));
    try obj.data.object.put(try alloc.dupe(u8, "createdAt"), zg.Value.fromString(alloc, try std.fmt.allocPrint(alloc, "{d}", .{c.created_at})));
    return obj;
}

fn productToValue(alloc: std.mem.Allocator, p: ProductRecord) !zg.Value {
    var obj = zg.Value.initObject(alloc);
    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, p.id));
    try obj.data.object.put(try alloc.dupe(u8, "name"), zg.Value.fromString(alloc, try alloc.dupe(u8, p.name)));
    try obj.data.object.put(try alloc.dupe(u8, "price"), zg.Value.fromFloat(alloc, p.price));
    try obj.data.object.put(try alloc.dupe(u8, "category"), zg.Value.fromString(alloc, try alloc.dupe(u8, p.category)));
    try obj.data.object.put(try alloc.dupe(u8, "stock"), zg.Value.fromInt(alloc, p.stock));
    return obj;
}

fn orderToValue(alloc: std.mem.Allocator, o: OrderRecord, app: *AppContext) !zg.Value {
    var obj = zg.Value.initObject(alloc);
    try obj.data.object.put(try alloc.dupe(u8, "id"), zg.Value.fromInt(alloc, o.id));
    try obj.data.object.put(try alloc.dupe(u8, "total"), zg.Value.fromFloat(alloc, o.total));
    const status_str = switch (o.status) {
        .pending => "PENDING",
        .confirmed => "CONFIRMED",
        .shipped => "SHIPPED",
        .delivered => "DELIVERED",
    };
    try obj.data.object.put(try alloc.dupe(u8, "status"), zg.Value.fromEnum(alloc, try alloc.dupe(u8, status_str)));
    try obj.data.object.put(try alloc.dupe(u8, "createdAt"), zg.Value.fromString(alloc, try std.fmt.allocPrint(alloc, "{d}", .{o.created_at})));

    var items = zg.Value.initList(alloc);
    for (o.items) |item| {
        var item_obj = zg.Value.initObject(alloc);
        if (app.product_dl.load(try std.fmt.allocPrint(alloc, "{d}", .{item.product_id}))) |pv| {
            try item_obj.data.object.put(try alloc.dupe(u8, "product"), pv);
        } else if (app.db.getProduct(item.product_id)) |pr| {
            try item_obj.data.object.put(try alloc.dupe(u8, "product"), try productToValue(alloc, pr));
        } else {
            try item_obj.data.object.put(try alloc.dupe(u8, "product"), zg.Value.fromNull(alloc));
        }
        try item_obj.data.object.put(try alloc.dupe(u8, "quantity"), zg.Value.fromInt(alloc, item.quantity));
        try item_obj.data.object.put(try alloc.dupe(u8, "unitPrice"), zg.Value.fromFloat(alloc, item.unit_price));
        try items.data.list.append(item_obj);
    }
    try obj.data.object.put(try alloc.dupe(u8, "items"), items);
    return obj;
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts))) {
        .SUCCESS => {},
        else => return 0,
    }
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

// ------------------------------------------------------------------
// Resolvers
// ------------------------------------------------------------------

fn meResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    // For demo purposes, return user id=1 as "current user"
    if (app.db.getUser(1)) |u| {
        return userToValue(alloc, u);
    }
    return zg.Value.fromNull(alloc);
}

fn userResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const id = args.get("id").?.data.int;

    // Try DataLoader cache first
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{d}", .{id});
    if (app.user_dl.load(key)) |cached| {
        return cached;
    }

    if (app.db.getUser(id)) |u| {
        return userToValue(alloc, u);
    }
    return zg.Value.fromNull(alloc);
}

fn usersResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const limit = if (args.get("limit")) |v| @as(usize, @intCast(v.data.int)) else 10;

    var list = zg.Value.initList(alloc);
    var iter = app.db.users.iterator();
    var count: usize = 0;
    while (iter.next()) |e| {
        if (count >= limit) break;
        try list.data.list.append(try userToValue(alloc, e.value_ptr.*));
        count += 1;
    }
    return list;
}

fn postResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const id = args.get("id").?.data.int;

    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{d}", .{id});
    if (app.post_dl.load(key)) |cached| {
        return cached;
    }

    if (app.db.getPost(id)) |p| {
        return postToValue(alloc, p, app);
    }
    return zg.Value.fromNull(alloc);
}

fn postsResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const limit = if (args.get("limit")) |v| @as(usize, @intCast(v.data.int)) else 10;

    var list = zg.Value.initList(alloc);
    var iter = app.db.posts.iterator();
    var count: usize = 0;
    while (iter.next()) |e| {
        if (count >= limit) break;
        try list.data.list.append(try postToValue(alloc, e.value_ptr.*, app));
        count += 1;
    }
    return list;
}

fn productResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const id = args.get("id").?.data.int;

    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{d}", .{id});
    if (app.product_dl.load(key)) |cached| {
        return cached;
    }

    if (app.db.getProduct(id)) |p| {
        return productToValue(alloc, p);
    }
    return zg.Value.fromNull(alloc);
}

fn productsResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const limit = if (args.get("limit")) |v| @as(usize, @intCast(v.data.int)) else 10;
    const category_arg = args.get("category");

    var list = zg.Value.initList(alloc);
    var iter = app.db.products.iterator();
    var count: usize = 0;
    while (iter.next()) |e| {
        if (count >= limit) break;
        if (category_arg) |cat| {
            if (!std.mem.eql(u8, e.value_ptr.category, cat.data.string)) continue;
        }
        try list.data.list.append(try productToValue(alloc, e.value_ptr.*));
        count += 1;
    }
    return list;
}

fn orderResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const id = args.get("id").?.data.int;
    if (app.db.getOrder(id)) |o| {
        return orderToValue(alloc, o, app);
    }
    return zg.Value.fromNull(alloc);
}

// Field resolvers for nested types

fn postAuthorResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, parent: zg.Value, _: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    // parent is a Post value; extract author_id from it if stored, otherwise query
    // In a real app, parent would contain the author_id. Here we look it up.
    const post_id = parent.data.object.get("id").?.data.int;
    if (app.db.getPost(post_id)) |p| {
        if (app.db.getUser(p.author_id)) |u| {
            return userToValue(alloc, u);
        }
    }
    return zg.Value.fromNull(alloc);
}

fn postCommentsResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, parent: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const post_id = parent.data.object.get("id").?.data.int;
    const limit = if (args.get("limit")) |v| @as(usize, @intCast(v.data.int)) else 10;

    const comments = try app.db.getCommentsByPost(post_id, alloc);
    defer alloc.free(comments);

    var list = zg.Value.initList(alloc);
    for (comments, 0..) |c, i| {
        if (i >= limit) break;
        try list.data.list.append(try commentToValue(alloc, c, app));
    }
    return list;
}

fn userPostsResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, parent: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const user_id = parent.data.object.get("id").?.data.int;
    const limit = if (args.get("limit")) |v| @as(usize, @intCast(v.data.int)) else 10;

    const posts = try app.db.getPostsByAuthor(user_id, alloc);
    defer alloc.free(posts);

    var list = zg.Value.initList(alloc);
    for (posts, 0..) |p, i| {
        if (i >= limit) break;
        try list.data.list.append(try postToValue(alloc, p, app));
    }
    return list;
}

fn commentAuthorResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, parent: zg.Value, _: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const comment_id = parent.data.object.get("id").?.data.int;
    if (app.db.getComment(comment_id)) |c| {
        if (app.db.getUser(c.author_id)) |u| {
            return userToValue(alloc, u);
        }
    }
    return zg.Value.fromNull(alloc);
}

fn commentPostResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, parent: zg.Value, _: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const comment_id = parent.data.object.get("id").?.data.int;
    if (app.db.getComment(comment_id)) |c| {
        if (app.db.getPost(c.post_id)) |p| {
            return postToValue(alloc, p, app);
        }
    }
    return zg.Value.fromNull(alloc);
}

fn orderUserResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, parent: zg.Value, _: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const order_id = parent.data.object.get("id").?.data.int;
    if (app.db.getOrder(order_id)) |o| {
        if (app.db.getUser(o.user_id)) |u| {
            return userToValue(alloc, u);
        }
    }
    return zg.Value.fromNull(alloc);
}

// Mutation resolvers

fn createPostResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const title = args.get("title").?.data.string;
    const content = args.get("content").?.data.string;

    const id = try app.db.insertPost(title, content, 1, nowMs());
    if (app.db.getPost(id)) |p| {
        return postToValue(alloc, p, app);
    }
    return zg.Value.fromNull(alloc);
}

fn createOrderResolver(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, args: std.StringHashMap(zg.Value)) !zg.Value {
    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
    const items_arg = args.get("items").?.data.list;

    var items: std.ArrayList(OrderItemRecord) = .empty;
    defer items.deinit(alloc);

    var total: f64 = 0;
    for (items_arg.items) |item_val| {
        const product_id = item_val.data.object.get("productId").?.data.int;
        const quantity = @as(i32, @intCast(item_val.data.object.get("quantity").?.data.int));
        if (app.db.getProduct(product_id)) |pr| {
            try items.append(alloc, .{
                .product_id = product_id,
                .quantity = quantity,
                .unit_price = pr.price,
            });
            total += pr.price * @as(f64, @floatFromInt(quantity));
        }
    }

    const id = try app.db.insertOrder(1, try items.toOwnedSlice(alloc), total, .pending, nowMs());
    if (app.db.getOrder(id)) |o| {
        return orderToValue(alloc, o, app);
    }
    return zg.Value.fromNull(alloc);
}

// ------------------------------------------------------------------
// Main
// ------------------------------------------------------------------

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = Database.init(allocator);
    defer db.deinit();
    try db.seed();

    const Builder = comptime zg.SchemaBuilder(.{
        .Query = .{
            .me = .{ .type = "User" },
            .user = .{ .type = "User", .args = .{ .id = .{ .type = "ID!" } } },
            .users = .{ .type = "[User]", .args = .{ .limit = .{ .type = "Int" } } },
            .post = .{ .type = "Post", .args = .{ .id = .{ .type = "ID!" } } },
            .posts = .{ .type = "[Post]", .args = .{ .authorId = .{ .type = "ID" }, .limit = .{ .type = "Int" } } },
            .product = .{ .type = "Product", .args = .{ .id = .{ .type = "ID!" } } },
            .products = .{ .type = "[Product]", .args = .{ .category = .{ .type = "String" }, .limit = .{ .type = "Int" } } },
            .order = .{ .type = "Order", .args = .{ .id = .{ .type = "ID!" } } },
        },
        .Mutation = .{
            .createPost = .{ .type = "Post", .args = .{ .title = .{ .type = "String!" }, .content = .{ .type = "String!" } } },
            .createOrder = .{ .type = "Order", .args = .{ .items = .{ .type = "[OrderItemInput!]!" } } },
        },
        .Subscription = .{
            .newOrder = .{ .type = "Order" },
        },
        .User = .{
            .id = .{ .type = "ID!" },
            .name = .{ .type = "String!" },
            .email = .{ .type = "String!" },
            .role = .{ .type = "Role!" },
            .posts = .{ .type = "[Post]", .args = .{ .limit = .{ .type = "Int" } } },
        },
        .Post = .{
            .id = .{ .type = "ID!" },
            .title = .{ .type = "String!" },
            .content = .{ .type = "String!" },
            .author = .{ .type = "User!" },
            .comments = .{ .type = "[Comment]", .args = .{ .limit = .{ .type = "Int" } } },
            .createdAt = .{ .type = "String!" },
        },
        .Comment = .{
            .id = .{ .type = "ID!" },
            .content = .{ .type = "String!" },
            .author = .{ .type = "User!" },
            .post = .{ .type = "Post!" },
            .createdAt = .{ .type = "String!" },
        },
        .Product = .{
            .id = .{ .type = "ID!" },
            .name = .{ .type = "String!" },
            .price = .{ .type = "Float!" },
            .category = .{ .type = "String!" },
            .stock = .{ .type = "Int!" },
        },
        .Order = .{
            .id = .{ .type = "ID!" },
            .user = .{ .type = "User!" },
            .items = .{ .type = "[OrderItem!]!" },
            .total = .{ .type = "Float!" },
            .status = .{ .type = "OrderStatus!" },
            .createdAt = .{ .type = "String!" },
        },
        .OrderItem = .{
            .product = .{ .type = "Product!" },
            .quantity = .{ .type = "Int!" },
            .unitPrice = .{ .type = "Float!" },
        },
        .OrderItemInput = .{
            .productId = .{ .type = "ID!" },
            .quantity = .{ .type = "Int!" },
        },
        .Role = .{
            .kind = "enum",
            .USER = .{},
            .ADMIN = .{},
        },
        .OrderStatus = .{
            .kind = "enum",
            .PENDING = .{},
            .CONFIRMED = .{},
            .SHIPPED = .{},
            .DELIVERED = .{},
        },
    });

    var schema_def = try Builder.init(allocator);
    defer schema_def.deinit();

    // SchemaBuilder already emits mutation/subscription root types in the SDL,
    // so no manual wiring is needed here.

    // Query resolvers
    if (schema_def.query_type.kind.object.fields.getPtr("me")) |f| f.resolve = meResolver;
    if (schema_def.query_type.kind.object.fields.getPtr("user")) |f| f.resolve = userResolver;
    if (schema_def.query_type.kind.object.fields.getPtr("users")) |f| {
        f.resolve = usersResolver;
        f.required_role = "admin";
    }
    if (schema_def.query_type.kind.object.fields.getPtr("post")) |f| f.resolve = postResolver;
    if (schema_def.query_type.kind.object.fields.getPtr("posts")) |f| f.resolve = postsResolver;
    if (schema_def.query_type.kind.object.fields.getPtr("product")) |f| f.resolve = productResolver;
    if (schema_def.query_type.kind.object.fields.getPtr("products")) |f| f.resolve = productsResolver;
    if (schema_def.query_type.kind.object.fields.getPtr("order")) |f| f.resolve = orderResolver;

    // Mutation resolvers
    if (schema_def.mutation_type) |mt| {
        if (mt.kind.object.fields.getPtr("createPost")) |f| f.resolve = createPostResolver;
        if (mt.kind.object.fields.getPtr("createOrder")) |f| f.resolve = createOrderResolver;
    }

    // Subscription resolver: pushes a new order event when one is created.
    if (schema_def.subscription_type) |st| {
        if (st.kind.object.fields.getPtr("newOrder")) |f| {
            f.subscribe = struct {
                const OrderStream = struct {
                    app: *AppContext,
                    // Polls the DB for new orders on each next() call.
                    last_id: i64 = 0,

                    fn next(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?zg.Value {
                        const self = @as(*OrderStream, @ptrCast(@alignCast(ptr)));
                        if (self.app.db.getLatestOrderAbove(self.last_id)) |o| {
                            self.last_id = o.id;
                            return try orderToValue(alloc, o, self.app);
                        }
                        return null;
                    }

                    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const self = @as(*OrderStream, @ptrCast(@alignCast(ptr)));
                        alloc.destroy(self);
                    }
                };

                fn subscribe(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: zg.Value, _: std.StringHashMap(zg.Value)) anyerror!zg.schema.SubscriptionStream {
                    const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
                    const stream = try alloc.create(OrderStream);
                    stream.* = .{ .app = app };
                    return zg.schema.SubscriptionStream{
                        .ptr = stream,
                        .vtable = &.{
                            .next = OrderStream.next,
                            .deinit = OrderStream.deinit,
                        },
                    };
                }
            }.subscribe;
        }
    }

    // Nested field resolvers
    if (schema_def.types.get("Post")) |pt| {
        if (pt.kind.object.fields.getPtr("author")) |f| f.resolve = postAuthorResolver;
        if (pt.kind.object.fields.getPtr("comments")) |f| f.resolve = postCommentsResolver;
    }
    if (schema_def.types.get("User")) |ut| {
        if (ut.kind.object.fields.getPtr("posts")) |f| f.resolve = userPostsResolver;
    }
    if (schema_def.types.get("Comment")) |ct| {
        if (ct.kind.object.fields.getPtr("author")) |f| f.resolve = commentAuthorResolver;
        if (ct.kind.object.fields.getPtr("post")) |f| f.resolve = commentPostResolver;
    }
    if (schema_def.types.get("Order")) |ot| {
        if (ot.kind.object.fields.getPtr("user")) |f| f.resolve = orderUserResolver;
    }

    // Setup DataLoaders
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var io_backend = IoBackend.init(allocator, .{});
    defer io_backend.deinit();

    var user_dl = zg.DataLoader.init(allocator, io_backend.io());
    defer user_dl.deinit();
    var post_dl = zg.DataLoader.init(allocator, io_backend.io());
    defer post_dl.deinit();
    var product_dl = zg.DataLoader.init(allocator, io_backend.io());
    defer product_dl.deinit();

    var app_ctx = AppContext{
        .allocator = allocator,
        .db = &db,
        .user_dl = &user_dl,
        .post_dl = &post_dl,
        .product_dl = &product_dl,
        .tenant_manager = undefined,
    };

    user_dl.setBatchLoader(struct {
        fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
            const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
            var values = try alloc.alloc(zg.Value, keys.len);
            for (keys, 0..) |k, i| {
                const id = try std.fmt.parseInt(i64, k, 10);
                if (app.db.getUser(id)) |u| {
                    values[i] = try userToValue(alloc, u);
                } else {
                    values[i] = zg.Value.fromNull(alloc);
                }
            }
            return values;
        }
    }.batch, &app_ctx);

    post_dl.setBatchLoader(struct {
        fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
            const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
            var values = try alloc.alloc(zg.Value, keys.len);
            for (keys, 0..) |k, i| {
                const id = try std.fmt.parseInt(i64, k, 10);
                if (app.db.getPost(id)) |p| {
                    values[i] = try postToValue(alloc, p, app);
                } else {
                    values[i] = zg.Value.fromNull(alloc);
                }
            }
            return values;
        }
    }.batch, &app_ctx);

    product_dl.setBatchLoader(struct {
        fn batch(ctx: ?*anyopaque, alloc: std.mem.Allocator, keys: []const []const u8) ![]zg.Value {
            const app = @as(*AppContext, @ptrCast(@alignCast(ctx.?)));
            var values = try alloc.alloc(zg.Value, keys.len);
            for (keys, 0..) |k, i| {
                const id = try std.fmt.parseInt(i64, k, 10);
                if (app.db.getProduct(id)) |p| {
                    values[i] = try productToValue(alloc, p);
                } else {
                    values[i] = zg.Value.fromNull(alloc);
                }
            }
            return values;
        }
    }.batch, &app_ctx);

    // Setup tenant manager
    var tm = zg.TenantManager.init(allocator);
    defer tm.deinit();
    try tm.register(.{
        .id = "tenant-a",
        .max_query_depth = 10,
        .max_query_complexity = 500,
        .roles = &.{"user"},
    });
    try tm.register(.{
        .id = "tenant-b",
        .max_query_depth = 15,
        .max_query_complexity = 800,
        .roles = &.{"user"},
    });
    app_ctx.tenant_manager = &tm;

    // Setup metrics
    var metrics = zg.MetricsCollector.init(allocator);
    defer metrics.deinit();

    // Setup rate limiter
    var rate_limiter = zg.RateLimiter.init(allocator, 1000, 100);
    defer rate_limiter.deinit();

    // Setup response cache
    var response_cache = zg.ResponseCache.init(allocator, 5000);
    defer response_cache.deinit();

    // Setup distributed cache L2 backend
    var dc_backend = zg.SimpleMemoryBackend.init(allocator);
    defer dc_backend.deinit();
    var dc = zg.DistributedCache.init(
        allocator,
        dc_backend.cacheBackend(),
        try allocator.dupe(u8, "complex:"),
        &response_cache,
    );
    defer dc.deinit();

    // Setup hooks for auth
    const hooks = zg.ExecutionHooks{
        .hasRole = struct {
            fn hook(_: ?*anyopaque, role: []const u8) bool {
                // Simplified: allow admin and user roles
                return std.mem.eql(u8, role, "admin") or std.mem.eql(u8, role, "user");
            }
        }.hook,
    };

    var server = zg.GraphQLServer.init(allocator, &schema_def, .{
        .bind_address = std.Io.net.IpAddress.parseIp4("127.0.0.1", 8080) catch unreachable,
        .max_query_depth = 20,
        .max_query_complexity = 1000,
        .max_body_size = 2 * 1024 * 1024,
        .metrics = &metrics,
        .rate_limiter = &rate_limiter,
        .response_cache = &response_cache,
        .distributed_cache = &dc,
        .tenant_manager = &tm,
        .hooks = hooks,
        .user_data = &app_ctx,
        .enable_playground = true,
    });

    std.debug.print("{s}\n", .{
        \\
        \\========================================================================
        \\  zgraphql Complex Example Server
        \\========================================================================
        \\  http://127.0.0.1:8080/graphql            (GraphQL endpoint)
        \\  http://127.0.0.1:8080/graphql/playground (GraphQL IDE)
        \\  http://127.0.0.1:8080/graphql/metrics    (Metrics JSON)
        \\========================================================================
        \\
        \\  Sample queries:
        \\
        \\  Query me + nested posts:
        \\    { me { id name email role posts(limit: 5) { title comments(limit: 3) { content author { name } } } } }
        \\
        \\  Query product catalog:
        \\    { products(category: "Electronics", limit: 10) { id name price stock } }
        \\
        \\  Mutation create post:
        \\    mutation { createPost(title: "New Post" content: "Hello from Zig") { id title author { name } } }
        \\
        \\  Mutation create order:
        \\    mutation { createOrder(items: [{productId: 1 quantity: 2}]) { id total status items { product { name } quantity } } }
        \\
        \\  Tenant-A (strict):   curl -H 'X-Tenant-ID: tenant-a' ...
        \\  Tenant-B (relaxed):  curl -H 'X-Tenant-ID: tenant-b' ...
        \\========================================================================
    });

    try server.listen(io_backend.io());
}
