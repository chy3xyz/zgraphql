const std = @import("std");
const Io = std.Io;

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// Structured audit log for GraphQL queries.
/// Writes one JSON Lines entry per query. Thread-safe via spinlock.
pub const AuditLog = struct {
    allocator: std.mem.Allocator,
    io: Io,
    file: ?std.Io.File,
    mutex: std.atomic.Mutex,
    write_offset: u64,

    pub const Entry = struct {
        timestamp_ms: i64,
        client_ip: ?[]const u8 = null,
        query: []const u8,
        operation_name: ?[]const u8 = null,
        duration_ms: f64,
        complexity: u64,
        had_error: bool,
        status_code: u16,
    };

    /// Create an audit log writing to the given file path.
    /// Opens the file in append mode, creating it if necessary.
    pub fn init(allocator: std.mem.Allocator, io: Io, path: []const u8) !AuditLog {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .read = false,
        });
        errdefer file.close(io);

        const stat = try file.stat(io);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .mutex = .unlocked,
            .write_offset = stat.size,
        };
    }

    /// Create an in-memory/no-op audit log (useful for testing).
    pub fn initNoOp(allocator: std.mem.Allocator, io: Io) AuditLog {
        return .{
            .allocator = allocator,
            .io = io,
            .file = null,
            .mutex = .unlocked,
            .write_offset = 0,
        };
    }

    pub fn deinit(self: *AuditLog) void {
        if (self.file) |f| f.close(self.io);
    }

    /// Record a single audit entry. Non-blocking except for the spinlock and file write.
    pub fn record(self: *AuditLog, entry: Entry) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        const f = self.file orelse return;
        const json_str = std.json.Stringify.valueAlloc(self.allocator, .{
            .timestamp_ms = entry.timestamp_ms,
            .client_ip = entry.client_ip,
            .query = entry.query,
            .operation_name = entry.operation_name,
            .duration_ms = entry.duration_ms,
            .complexity = entry.complexity,
            .had_error = entry.had_error,
            .status_code = entry.status_code,
        }, .{}) catch return;
        defer self.allocator.free(json_str);

        const line = std.mem.concat(self.allocator, u8, &.{ json_str, "\n" }) catch return;
        defer self.allocator.free(line);

        f.writePositionalAll(self.io, line, self.write_offset) catch return;
        self.write_offset += line.len;
    }
};

test "AuditLog no-op" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var log = AuditLog.initNoOp(allocator, io);
    defer log.deinit();

    log.record(.{
        .timestamp_ms = 1234567890,
        .client_ip = "127.0.0.1",
        .query = "{ hello }",
        .duration_ms = 1.5,
        .complexity = 1,
        .had_error = false,
        .status_code = 200,
    });
}

test "AuditLog file write" {
    const allocator = std.testing.allocator;
    const path = "/tmp/zgraphql_audit_test.jsonl";

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var log = try AuditLog.init(allocator, io, path);
    defer log.deinit();

    log.record(.{
        .timestamp_ms = 1234567890,
        .client_ip = "127.0.0.1",
        .query = "{ hello }",
        .duration_ms = 1.5,
        .complexity = 1,
        .had_error = false,
        .status_code = 200,
    });

    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(4096));
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "127.0.0.1") != null);
}
