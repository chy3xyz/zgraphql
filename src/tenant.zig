const std = @import("std");
const Schema = @import("schema.zig").Schema;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const QueryCache = @import("query_cache.zig").QueryCache;

/// Tenant represents an isolated tenant configuration.
/// Each tenant may have its own resource limits, schema overrides,
/// query whitelist, and rate limiter.
pub const Tenant = struct {
    /// Unique tenant identifier.
    id: []const u8,
    /// Human-readable display name.
    display_name: []const u8 = "",
    /// Optional per-tenant schema override.
    /// If null, the server's default schema is used.
    schema: ?*Schema = null,
    /// Optional per-tenant query depth limit.
    max_query_depth: ?usize = null,
    /// Optional per-tenant query complexity limit.
    max_query_complexity: ?usize = null,
    /// Optional per-tenant body size limit.
    max_body_size: ?usize = null,
    /// Optional per-tenant rate limiter.
    rate_limiter: ?*RateLimiter = null,
    /// Optional per-tenant query cache (whitelist / persisted queries).
    query_cache: ?*QueryCache = null,
    /// Whether to enforce the tenant's query whitelist.
    enforce_query_whitelist: bool = false,
    /// Roles assigned to this tenant.
    roles: []const []const u8 = &.{},
};

/// TenantManager handles tenant registration and request-scoped resolution.
///
/// Usage:
///   var tm = TenantManager.init(allocator);
///   defer tm.deinit();
///   try tm.register(.{ .id = "tenant-a", .max_query_depth = 10 });
pub const TenantManager = struct {
    allocator: std.mem.Allocator,
    tenants: std.StringHashMap(Tenant),
    default_tenant: ?Tenant = null,
    /// HTTP header used to extract the tenant ID from incoming requests.
    header_name: []const u8,

    pub fn init(allocator: std.mem.Allocator) TenantManager {
        return .{
            .allocator = allocator,
            .tenants = std.StringHashMap(Tenant).init(allocator),
            .header_name = "X-Tenant-ID",
        };
    }

    pub fn deinit(self: *TenantManager) void {
        var iter = self.tenants.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tenants.deinit();
        if (self.default_tenant) |*dt| {
            self.allocator.free(dt.id);
            self.allocator.free(dt.display_name);
        }
    }

    /// Set the header name used for tenant resolution (default: X-Tenant-ID).
    pub fn setHeaderName(self: *TenantManager, name: []const u8) !void {
        self.header_name = try self.allocator.dupe(u8, name);
    }

    /// Register a new tenant. The tenant ID is copied.
    pub fn register(self: *TenantManager, tenant: Tenant) !void {
        const id_copy = try self.allocator.dupe(u8, tenant.id);
        errdefer self.allocator.free(id_copy);
        var tenant_copy = tenant;
        tenant_copy.id = id_copy;
        try self.tenants.put(id_copy, tenant_copy);
    }

    /// Set the default tenant used when no tenant ID is found in a request.
    pub fn setDefault(self: *TenantManager, tenant: Tenant) !void {
        self.default_tenant = .{
            .id = try self.allocator.dupe(u8, tenant.id),
            .display_name = try self.allocator.dupe(u8, tenant.display_name),
            .schema = tenant.schema,
            .max_query_depth = tenant.max_query_depth,
            .max_query_complexity = tenant.max_query_complexity,
            .max_body_size = tenant.max_body_size,
            .rate_limiter = tenant.rate_limiter,
            .query_cache = tenant.query_cache,
            .enforce_query_whitelist = tenant.enforce_query_whitelist,
            .roles = tenant.roles,
        };
    }

    /// Resolve a tenant from raw HTTP request headers.
    /// `headers` is the raw HTTP head buffer (e.g. request.head_buffer).
    /// Returns a pointer to the registered tenant, or the default tenant,
    /// or null if neither exists.
    pub fn resolve(self: *TenantManager, headers: []const u8) ?*Tenant {
        const tenant_id = findHeaderValue(headers, self.header_name) orelse {
            if (self.default_tenant) |*dt| return dt;
            return null;
        };
        return self.tenants.getPtr(tenant_id);
    }

    /// Resolve a tenant by explicit ID string.
    pub fn resolveById(self: *TenantManager, id: []const u8) ?*Tenant {
        return self.tenants.getPtr(id);
    }
};

/// Find a header value in a raw HTTP head buffer.
/// The buffer is expected to contain lines like "Header-Name: value\r\n".
fn findHeaderValue(buffer: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < buffer.len) {
        const line_end = std.mem.indexOfPos(u8, buffer, i, "\r\n") orelse break;
        const line = buffer[i..line_end];
        const colon = std.mem.indexOf(u8, line, ":");
        if (colon) |c| {
            const key = std.mem.trim(u8, line[0..c], " \t");
            if (std.ascii.eqlIgnoreCase(key, name)) {
                return std.mem.trim(u8, line[c + 1 ..], " \t");
            }
        }
        i = line_end + 2;
    }
    return null;
}

/// TenantContext holds the resolved tenant for the duration of a request.
/// It is passed to the Executor via user_data when tenant isolation is enabled.
pub const TenantContext = struct {
    tenant: *Tenant,
    tenant_manager: *TenantManager,
};

/// Helper to build an ExecutionHooks wrapper that injects tenant roles
/// into the hasRole check.
pub fn tenantHooks(base: @import("executor.zig").ExecutionHooks) @import("executor.zig").ExecutionHooks {
    var hooks = base;
    hooks.hasRole = struct {
        fn check(ctx: ?*anyopaque, role: []const u8) bool {
            const tc = @as(*TenantContext, @ptrCast(@alignCast(ctx.?)));
            // Check tenant-specific roles first
            for (tc.tenant.roles) |r| {
                if (std.mem.eql(u8, r, role)) return true;
            }
            // Fall back to base hook if available
            return if (base.hasRole) |base_hook| base_hook(ctx, role) else false;
        }
    }.check;
    return hooks;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "TenantManager register and resolveById" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.register(.{
        .id = "tenant-a",
        .display_name = "Tenant A",
        .max_query_depth = 10,
    });

    const t = tm.resolveById("tenant-a");
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("tenant-a", t.?.id);
    try std.testing.expectEqual(@as(?usize, 10), t.?.max_query_depth);

    const missing = tm.resolveById("tenant-b");
    try std.testing.expect(missing == null);
}

test "TenantManager resolve from headers" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.register(.{
        .id = "alpha",
        .max_query_complexity = 500,
    });

    const headers = "GET /graphql HTTP/1.1\r\nHost: localhost\r\nX-Tenant-ID: alpha\r\n\r\n";
    const t = tm.resolve(headers);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("alpha", t.?.id);
    try std.testing.expectEqual(@as(?usize, 500), t.?.max_query_complexity);
}

test "TenantManager resolve missing header falls back to default" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    try tm.setDefault(.{
        .id = "default",
        .max_query_depth = 5,
    });

    const headers = "GET /graphql HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const t = tm.resolve(headers);
    try std.testing.expect(t != null);
    try std.testing.expectEqualStrings("default", t.?.id);
    try std.testing.expectEqual(@as(?usize, 5), t.?.max_query_depth);
}

test "TenantManager resolve unknown tenant returns null without default" {
    var tm = TenantManager.init(std.testing.allocator);
    defer tm.deinit();

    const headers = "GET /graphql HTTP/1.1\r\nHost: localhost\r\nX-Tenant-ID: unknown\r\n\r\n";
    const t = tm.resolve(headers);
    try std.testing.expect(t == null);
}

test "findHeaderValue case insensitive" {
    const headers = "GET / HTTP/1.1\r\nContent-Type: application/json\r\nX-Custom: hello\r\n\r\n";
    try std.testing.expectEqualStrings("application/json", findHeaderValue(headers, "content-type").?);
    try std.testing.expectEqualStrings("hello", findHeaderValue(headers, "X-Custom").?);
    try std.testing.expect(findHeaderValue(headers, "missing") == null);
}
