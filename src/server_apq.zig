//! Automatic Persisted Query (APQ) resolution.
//! Split out of server.zig to keep that file focused on request handling.

const std = @import("std");
const server = @import("server.zig");

const GraphQLServer = server.GraphQLServer;
const QueryCache = @import("query_cache.zig").QueryCache;

/// Returns true if the signature is valid or no secret is configured.
pub fn verifyApqSignature(secret: ?[]const u8, hash: []const u8, signature: ?[]const u8) bool {
    const s = secret orelse return true;
    const sig = signature orelse return false;

    var mac_bytes: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_bytes, hash, s);
    const expected_hex = std.fmt.bytesToHex(mac_bytes, .lower);

    if (sig.len != expected_hex.len) return false;
    var diff: u8 = 0;
    for (sig, expected_hex) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

/// Resolve an APQ (Automatic Persisted Query) hash.
/// Returns an owned query string to execute, or null if an error response was already sent.
/// Caller owns the returned string (if non-null) and must free it.
///
/// Ownership contract: `provided_query` must be owned by the caller. This
/// function takes ownership: on success it either returns `provided_query`
/// itself (transferring ownership back) or returns a fresh owned copy; on
/// business failure (returning null) it frees `provided_query`. On error
/// propagation (an error is returned) `provided_query` is NOT freed — the
/// caller's own cleanup (e.g. a deferred free) remains responsible for it.
pub fn resolvePersistedQuery(self: *GraphQLServer, request: *std.http.Server.Request, hash: []const u8, provided_query: ?[]const u8, signature: ?[]const u8, origin: []const u8) !?[]const u8 {
    if (!verifyApqSignature(self.options.apq_hmac_secret, hash, signature)) {
        try server.sendGraphQLErrorResponse(self.allocator, request, "PersistedQuery.InvalidSignature", .bad_request, origin);
        if (provided_query) |q| self.allocator.free(q);
        return null;
    }

    const cache = self.options.query_cache orelse {
        // No cache configured; if whitelist is on, reject
        if (self.options.enforce_query_whitelist) {
            try server.sendGraphQLErrorResponse(self.allocator, request, "PersistedQueryNotFound", .ok, origin);
            if (provided_query) |q| self.allocator.free(q);
            return null;
        }
        return provided_query;
    };

    // Cache hit: getInsensitive returns an owned copy. The caller frees it.
    if (cache.getInsensitive(hash)) |cached_query| {
        if (provided_query) |q| self.allocator.free(q);
        return cached_query;
    }

    if (provided_query) |query| {
        // Verify the hash matches the provided query (case-insensitive)
        const computed = try QueryCache.computeHash(self.allocator, query);
        defer self.allocator.free(computed);
        const hash_match = std.mem.eql(u8, computed, hash) or blk: {
            const lower_hash = try self.allocator.alloc(u8, hash.len);
            defer self.allocator.free(lower_hash);
            _ = std.ascii.lowerString(lower_hash, hash);
            break :blk std.mem.eql(u8, computed, lower_hash);
        };
        if (!hash_match) {
            try server.sendGraphQLErrorResponse(self.allocator, request, "Provided sha does not match query", .bad_request, origin);
            self.allocator.free(query);
            return null;
        }

        // In whitelist mode, don't auto-register new queries
        if (!self.options.enforce_query_whitelist) {
            try cache.store(query);
        }
        return query;
    }

    // Hash not found and no query provided
    try server.sendGraphQLErrorResponse(self.allocator, request, "PersistedQueryNotFound", .ok, origin);
    return null;
}

/// Batch-safe variant of resolvePersistedQuery that does not send HTTP responses.
/// Returns null on any APQ failure (caller should produce a GraphQL error JSON).
///
/// Ownership contract (same as resolvePersistedQuery): `provided_query` must be
/// owned by the caller. On success this returns an owned string (either
/// `provided_query` itself or a fresh copy); on failure it frees
/// `provided_query` and returns null.
pub fn resolvePersistedQueryBatch(self: *GraphQLServer, hash: []const u8, provided_query: ?[]const u8, signature: ?[]const u8) !?[]const u8 {
    if (!verifyApqSignature(self.options.apq_hmac_secret, hash, signature)) {
        if (provided_query) |q| self.allocator.free(q);
        return null;
    }

    const cache = self.options.query_cache orelse {
        if (self.options.enforce_query_whitelist) {
            if (provided_query) |q| self.allocator.free(q);
            return null;
        }
        return provided_query;
    };

    if (cache.getInsensitive(hash)) |cached_query| {
        if (provided_query) |q| self.allocator.free(q);
        return cached_query;
    }

    if (provided_query) |query| {
        const computed = try QueryCache.computeHash(self.allocator, query);
        defer self.allocator.free(computed);
        const hash_match = std.mem.eql(u8, computed, hash) or blk: {
            const lower_hash = try self.allocator.alloc(u8, hash.len);
            defer self.allocator.free(lower_hash);
            _ = std.ascii.lowerString(lower_hash, hash);
            break :blk std.mem.eql(u8, computed, lower_hash);
        };
        if (!hash_match) {
            self.allocator.free(query);
            return null;
        }

        if (!self.options.enforce_query_whitelist) {
            try cache.store(query);
        }
        return query;
    }

    return null;
}

/// Test helper for computing a hex HMAC signature (used by unit tests).
pub fn computeApqSignatureForTest(hash: []const u8, secret: []const u8) [std.crypto.auth.hmac.sha2.HmacSha256.mac_length * 2]u8 {
    var mac_bytes: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_bytes, hash, secret);
    return std.fmt.bytesToHex(mac_bytes, .lower);
}
