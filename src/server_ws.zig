//! WebSocket (graphql-ws protocol) handling for the GraphQL server.
//! Split out of server.zig to keep that file focused on HTTP request handling.

const std = @import("std");
const server = @import("server.zig");
const schema = @import("schema.zig");
const Value = @import("value.zig").Value;
const Parser = @import("parser.zig").Parser;
const Executor = @import("executor.zig").Executor;

const GraphQLServer = server.GraphQLServer;
const Io = std.Io;
const http = std.http;
const log = std.log.scoped(.zgraphql_server);

pub fn readPayloadLen(in: *std.Io.Reader, h1: std.http.Server.WebSocket.Header1) !usize {
    return switch (h1.payload_len) {
        .len16 => try in.takeInt(u16, .big),
        .len64 => std.math.cast(usize, try in.takeInt(u64, .big)) orelse return error.MessageOversize,
        else => @intFromEnum(h1.payload_len),
    };
}

/// Read a WebSocket message, supporting fragmented frames and payloads larger
/// than the input buffer. Caller owns the returned memory.
pub fn readWebSocketMessage(allocator: std.mem.Allocator, ws: *http.Server.WebSocket, max_size: usize) !?[]u8 {
    const in = ws.input;

    var opcode: ?std.http.Server.WebSocket.Opcode = null;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    while (true) {
        const header = try in.takeArray(2);
        const h0: std.http.Server.WebSocket.Header0 = @bitCast(header[0]);
        const h1: std.http.Server.WebSocket.Header1 = @bitCast(header[1]);

        switch (h0.opcode) {
            .text, .binary, .pong, .ping => {},
            .connection_close => return error.ConnectionClose,
            .continuation => {},
            _ => return error.UnexpectedOpCode,
        }

        if (!h1.mask) return error.MissingMaskBit;

        const plen = try readPayloadLen(in, h1);
        const mask: u32 = @bitCast((try in.takeArray(4)).*);

        // Handle control frames inline
        if (h0.opcode == .ping) {
            const ping_buf = try allocator.alloc(u8, plen);
            defer allocator.free(ping_buf);
            try in.readSliceAll(ping_buf);
            try ws.writeMessage(ping_buf, .pong);
            continue;
        }
        if (h0.opcode == .pong) {
            const pong_buf = try allocator.alloc(u8, plen);
            defer allocator.free(pong_buf);
            try in.readSliceAll(pong_buf);
            continue;
        }

        // Read payload
        var payload: []u8 = undefined;
        var owned = false;
        if (plen > in.buffer.len) {
            payload = try allocator.alloc(u8, plen);
            owned = true;
            try in.readSliceAll(payload);
        } else {
            payload = try in.take(plen);
        }

        // Unmask payload
        const floored_len = (payload.len / 4) * 4;
        const u32_payload: []align(1) u32 = @ptrCast(payload[0..floored_len]);
        for (u32_payload) |*elem| elem.* ^= mask;
        const mask_bytes: []const u8 = @ptrCast(&mask);
        for (payload[floored_len..], mask_bytes[0 .. payload.len - floored_len]) |*leftover, m|
            leftover.* ^= m;

        if (opcode == null) {
            if (h0.opcode == .continuation) return error.UnexpectedOpCode;
            opcode = h0.opcode;
        }

        try buf.appendSlice(payload);
        if (buf.items.len > max_size) {
            if (owned) allocator.free(payload);
            return error.MessageTooLarge;
        }
        if (owned) allocator.free(payload);

        if (h0.fin) break;
    }

    if (buf.items.len == 0) return null;
    return try allocator.dupe(u8, buf.items);
}

pub const ActiveSubscription = struct {
    stream: schema.SubscriptionStream,
    future: Io.Future(Io.Cancelable!void),
    id: []const u8,
};

/// Consume a subscription stream in a concurrent task, sending events over WebSocket.
pub fn consumeSubscription(
    self: *GraphQLServer,
    io: Io,
    ws: *http.Server.WebSocket,
    ws_mutex: *std.Io.Mutex,
    stream: schema.SubscriptionStream,
    id: []const u8,
) Io.Cancelable!void {
    defer stream.deinit(self.allocator);
    while (true) {
        io.checkCancel() catch return;

        var event = stream.next(self.allocator) catch |err| {
            log.err("subscription stream error: {s}", .{@errorName(err)});
            const err_json = server.buildErrorJson(self.allocator, "Subscription stream error") catch break;
            defer self.allocator.free(err_json);
            const response = std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json }) catch break;
            defer self.allocator.free(response);
            ws_mutex.lock(io) catch break;
            defer ws_mutex.unlock(io);
            ws.writeMessage(response, .text) catch |werr| {
                log.err("websocket write error (subscription error): {s}", .{@errorName(werr)});
            };
            break;
        } orelse break;
        defer event.deinit(self.allocator);

        const json_str = event.toJson(self.allocator) catch {
            log.err("subscription json serialization failed", .{});
            break;
        };
        defer self.allocator.free(json_str);

        const response = std.fmt.allocPrint(self.allocator, "{{\"type\":\"next\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, json_str }) catch break;
        defer self.allocator.free(response);

        ws_mutex.lock(io) catch break;
        defer ws_mutex.unlock(io);
        ws.writeMessage(response, .text) catch |werr| {
            log.err("websocket write error (subscription next): {s}", .{@errorName(werr)});
        };
    }

    // Send complete
    const complete_response = std.fmt.allocPrint(self.allocator, "{{\"type\":\"complete\",\"id\":\"{s}\"}}", .{id}) catch return;
    defer self.allocator.free(complete_response);
    ws_mutex.lock(io) catch return;
    defer ws_mutex.unlock(io);
    ws.writeMessage(complete_response, .text) catch |werr| {
        log.err("websocket write error (subscription complete): {s}", .{@errorName(werr)});
    };

}

/// Handle WebSocket connection using graphql-ws protocol.
pub fn handleWebSocket(self: *GraphQLServer, io: Io, ws: *http.Server.WebSocket) !void {
    // Wait for connection_init
    const init_msg_data = readWebSocketMessage(self.allocator, ws, self.options.max_websocket_message_size) catch |err| switch (err) {
        error.ConnectionClose => return,
        else => {
            log.err("websocket read error: {s}", .{@errorName(err)});
            return;
        },
    };
    defer if (init_msg_data) |d| self.allocator.free(d);

    // Parse connection_init
    const init_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, init_msg_data orelse "{}", .{}) catch {
        try ws.writeMessage("{\"type\":\"connection_error\"}", .text);
        return;
    };
    defer init_parsed.deinit();

    const msg_type_ok = if (init_parsed.value.object.get("type")) |t| t == .string and std.mem.eql(u8, t.string, "connection_init") else false;
    if (init_parsed.value != .object or !msg_type_ok) {
        try ws.writeMessage("{\"type\":\"connection_error\"}", .text);
        return;
    }

    // Send connection_ack
    try ws.writeMessage("{\"type\":\"connection_ack\"}", .text);

    var ws_mutex = std.Io.Mutex.init;
    var active_subs = std.StringHashMap(ActiveSubscription).init(self.allocator);
    defer {
        // Cancel all active subscriptions on disconnect and await completion
        var iter = active_subs.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.stream.cancel();
            _ = entry.value_ptr.future.cancel(io) catch {};
            _ = entry.value_ptr.future.await(io) catch {};
            self.allocator.free(entry.value_ptr.id);
        }
        active_subs.deinit();
    }

    // Message loop
    while (true) {
        const msg_data = readWebSocketMessage(self.allocator, ws, self.options.max_websocket_message_size) catch |err| switch (err) {
            error.ConnectionClose => return,
            else => {
                log.err("websocket read error: {s}", .{@errorName(err)});
                return;
            },
        };
        defer if (msg_data) |d| self.allocator.free(d);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg_data orelse "{}", .{}) catch continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const msg_type = if (obj.get("type")) |t| (if (t == .string) t.string else continue) else continue;

        if (std.mem.eql(u8, msg_type, "ping")) {
            try ws.writeMessage("{\"type\":\"pong\"}", .text);
            continue;
        }

        if (std.mem.eql(u8, msg_type, "subscribe")) {
            const id = if (obj.get("id")) |id_val| (if (id_val == .string) id_val.string else "") else "";
            const payload = if (obj.get("payload")) |p| (if (p == .object) p else continue) else continue;

            var query_str: ?[]const u8 = null;
            var operation_name: ?[]const u8 = null;
            var variables = std.StringHashMap(Value).init(self.allocator);
            defer {
                var viter = variables.iterator();
                while (viter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(self.allocator);
                }
                variables.deinit();
            }

            if (payload.object.get("query")) |q| {
                if (q == .string) query_str = q.string;
            }
            if (payload.object.get("operationName")) |op| {
                if (op == .string) operation_name = op.string;
            }
            if (payload.object.get("variables")) |vars| {
                if (vars == .object) {
                    var viter = vars.object.iterator();
                    while (viter.next()) |entry| {
                        try variables.put(try self.allocator.dupe(u8, entry.key_ptr.*), try server.jsonToGraphQLValue(self.allocator, entry.value_ptr.*));
                    }
                }
            }

            const query = query_str orelse {
                const err_json = try server.buildErrorJson(self.allocator, "Missing query");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };

            // Parse document to determine operation type
            var parser = Parser.init(self.allocator, query) catch |err| {
                log.err("websocket parser init error: {s}", .{@errorName(err)});
                const err_json = try server.buildErrorJson(self.allocator, "Parser error");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };
            defer parser.deinit();
            var doc = parser.parseDocument() catch |err| {
                log.err("websocket parse error: {s}", .{@errorName(err)});
                const err_json = try server.buildErrorJson(self.allocator, "Syntax error");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };
            defer doc.deinit();

            // Detect subscription operation
            var is_subscription = false;
            for (doc.definitions.items) |*def| {
                switch (def.*) {
                    .operation => |*op| {
                        if (operation_name) |name| {
                            if (op.name != null and std.mem.eql(u8, op.name.?, name)) {
                                is_subscription = op.op_type == .subscription;
                                break;
                            }
                        } else {
                            if (!is_subscription) {
                                is_subscription = op.op_type == .subscription;
                            }
                        }
                    },
                    else => {},
                }
            }

            if (is_subscription) {
                // Cancel any existing subscription with the same ID
                if (active_subs.getPtr(id)) |existing| {
                    existing.stream.cancel();
                    _ = existing.future.cancel(io) catch {};
                    // Await to ensure the future finishes before we free its resources
                    _ = existing.future.await(io) catch {};
                    self.allocator.free(existing.id);
                    _ = active_subs.remove(id);
                }

                var executor = Executor.init(self.allocator, self.schema_def, io);
                defer executor.deinit();
                try executor.setVariables(variables);
                if (self.options.hooks) |hooks| executor.hooks = hooks;
                if (self.options.user_data) |user_data| executor.setUserData(user_data);

                var stream = executor.executeSubscription(&doc) catch |err| {
                    log.err("websocket subscription error: {s}", .{@errorName(err)});
                    const err_json = try server.buildErrorJson(self.allocator, "Subscription error");
                    defer self.allocator.free(err_json);
                    const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                    defer self.allocator.free(response);
                    try ws.writeMessage(response, .text);
                    continue;
                };
                errdefer stream.deinit(self.allocator);

                const id_copy = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(id_copy);

                const future = try Io.concurrent(io, consumeSubscription, .{ self, io, ws, &ws_mutex, stream, id_copy });

                try active_subs.put(id_copy, .{
                    .stream = stream,
                    .future = future,
                    .id = id_copy,
                });
                continue;
            }

            // Non-subscription: single-shot execution
            const result = server.executeGraphQLAndGetJson(self, io, query, operation_name, &variables, null) catch |err| {
                log.err("websocket execution error: {s}", .{@errorName(err)});
                const err_json = try server.buildErrorJson(self.allocator, "Internal error");
                defer self.allocator.free(err_json);
                const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, err_json });
                defer self.allocator.free(response);
                try ws.writeMessage(response, .text);
                continue;
            };
            defer self.allocator.free(result.json_str);

            // Send next with payload
            const next_response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"next\",\"id\":\"{s}\",\"payload\":{s}}}", .{ id, result.json_str });
            defer self.allocator.free(next_response);
            try ws.writeMessage(next_response, .text);

            // Send complete
            const complete_response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"complete\",\"id\":\"{s}\"}}", .{id});
            defer self.allocator.free(complete_response);
            try ws.writeMessage(complete_response, .text);
            continue;
        }

        if (std.mem.eql(u8, msg_type, "complete")) {
            const id = if (obj.get("id")) |id_val| (if (id_val == .string) id_val.string else continue) else continue;
            if (active_subs.getPtr(id)) |entry| {
                entry.stream.cancel();
                _ = entry.future.cancel(io) catch {};
                self.allocator.free(entry.id);
                _ = active_subs.remove(id);
            }
            continue;
        }
    }
}

