const std = @import("std");
const ast = @import("ast.zig");
const schema = @import("schema.zig");
const Value = @import("value.zig").Value;
const DataLoader = @import("dataloader.zig").DataLoader;
const Introspection = @import("introspection.zig").Introspection;
const Io = std.Io;

pub const ExecutionError = error{
    ResolverError,
    InvalidField,
    InvalidArgument,
    NullValueForNonNull,
    Unauthorized,
    PermissionDenied,
    NotFound,
    Timeout,
    InvalidInput,
    ExternalServiceError,
    RateLimited,
} || std.mem.Allocator.Error;

/// GraphQL spec-compliant error.
pub const GraphQLError = struct {
    message: []const u8,
    /// Path from the response root to the field that produced the error.
    /// Each element is a field name or list index.
    path: ?[]const []const u8 = null,

    pub fn deinit(self: *GraphQLError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.path) |path| {
            for (path) |segment| allocator.free(segment);
            allocator.free(path);
        }
    }
};

/// Execution context passed to resolvers.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    schema_def: *schema.Schema,
    variables: std.StringHashMap(Value),
    // User can attach custom data.
    user_data: ?*anyopaque = null,
    // Optional request-level DataLoader for N+1 optimization.
    dataloader: ?*DataLoader = null,
};

/// Hooks for observability, auth, and metrics.
pub const ExecutionHooks = struct {
    /// Called before each field is executed. Return false to abort (returns null + error).
    before_field_execute: ?*const fn (ctx: ?*anyopaque, field_name: []const u8) bool = null,
    /// Called after each field completes (success or error).
    /// `duration_ns` is the wall-clock time spent in this field (including sub-selections).
    after_field_execute: ?*const fn (ctx: ?*anyopaque, field_name: []const u8, had_error: bool, duration_ns: u64) void = null,
    /// Called when an error is recorded.
    on_error: ?*const fn (ctx: ?*anyopaque, message: []const u8) void = null,
    /// Return true if the current user has the given role.
    /// Used for field-level authorization when `Field.required_role` is set.
    hasRole: ?*const fn (ctx: ?*anyopaque, role: []const u8) bool = null,
};

/// Executor runs GraphQL operations against a schema.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    schema_def: *schema.Schema,
    context: Context,
    hooks: ExecutionHooks = .{},
    // Execution state (valid during execute/executeNamed).
    document: ?*ast.Document = null,
    fragments: std.StringHashMap(*ast.FragmentDefinition),
    errors: std.array_list.Managed(GraphQLError),

    pub fn init(allocator: std.mem.Allocator, schema_def: *schema.Schema, io: std.Io) Executor {
        return .{
            .allocator = allocator,
            .schema_def = schema_def,
            .context = .{
                .allocator = allocator,
                .io = io,
                .schema_def = schema_def,
                .variables = std.StringHashMap(Value).init(allocator),
            },
            .fragments = std.StringHashMap(*ast.FragmentDefinition).init(allocator),
            .errors = std.array_list.Managed(GraphQLError).init(allocator),
        };
    }

    pub fn deinit(self: *Executor) void {
        var viter = self.context.variables.iterator();
        while (viter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.context.variables.deinit();
        self.clearFragments();
        self.fragments.deinit();
        self.clearErrors();
        self.errors.deinit();
    }

    fn clearFragments(self: *Executor) void {
        var iter = self.fragments.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.fragments.clearRetainingCapacity();
    }

    fn clearErrors(self: *Executor) void {
        for (self.errors.items) |*err| err.deinit(self.allocator);
        self.errors.clearRetainingCapacity();
    }

    /// Duplicate a path by appending an extra segment.
    fn dupePath(self: *Executor, prefix: []const []const u8, extra: []const u8) std.mem.Allocator.Error![]const []const u8 {
        const result = try self.allocator.alloc([]const u8, prefix.len + 1);
        errdefer self.allocator.free(result);
        for (prefix, 0..) |seg, i| {
            result[i] = try self.allocator.dupe(u8, seg);
        }
        result[prefix.len] = try self.allocator.dupe(u8, extra);
        return result;
    }

    /// Free a duplicated path.
    fn freePath(self: *Executor, path: []const []const u8) void {
        for (path) |seg| self.allocator.free(seg);
        self.allocator.free(path);
    }

    pub fn setVariables(self: *Executor, variables: std.StringHashMap(Value)) std.mem.Allocator.Error!void {
        // Deep copy the variables HashMap
        var iter = self.context.variables.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.context.variables.clearRetainingCapacity();

        var src_iter = variables.iterator();
        while (src_iter.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key);
            var val = try entry.value_ptr.clone();
            errdefer val.deinit();
            try self.context.variables.put(key, val);
        }
    }

    pub fn setUserData(self: *Executor, user_data: *anyopaque) void {
        self.context.user_data = user_data;
    }

    pub fn execute(self: *Executor, doc: *ast.Document) ExecutionError!Value {
        return self.executeNamed(doc, null);
    }

    pub fn executeNamed(self: *Executor, doc: *ast.Document, operation_name: ?[]const u8) ExecutionError!Value {
        self.document = doc;
        self.clearFragments();
        self.clearErrors();
        defer {
            self.document = null;
            self.clearFragments();
        }

        // Collect fragment definitions
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .fragment => |*frag| {
                    try self.fragments.put(try self.allocator.dupe(u8, frag.name), frag);
                },
                else => {},
            }
        }

        // Find operation definition
        var op_def: ?*ast.OperationDefinition = null;
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .operation => |*op| {
                    if (operation_name) |name| {
                        if (op.name != null and std.mem.eql(u8, op.name.?, name)) {
                            op_def = op;
                            break;
                        }
                    } else {
                        if (op_def == null) {
                            op_def = op;
                        } else {
                            return error.ResolverError; // Multiple anonymous operations
                        }
                    }
                },
                else => {},
            }
        }

        const op = op_def orelse return error.ResolverError;

        // Fill in default values for variables not provided by the client
        for (op.variable_definitions.items) |*vd| {
            if (!self.context.variables.contains(vd.name)) {
                if (vd.default_value) |*dv| {
                    const default_val = try self.coerceValue(dv.*);
                    try self.context.variables.put(try self.allocator.dupe(u8, vd.name), default_val);
                }
            }
        }

        return try self.executeOperation(op);
    }

    fn executeOperation(self: *Executor, op: *ast.OperationDefinition) ExecutionError!Value {
        const root_type = switch (op.op_type) {
            .query => self.schema_def.query_type,
            .mutation => self.schema_def.mutation_type orelse return error.ResolverError,
            .subscription => self.schema_def.subscription_type orelse return error.ResolverError,
        };

        var result = Value.initObject(self.allocator);
        errdefer result.deinit();

        const data = try self.executeSelectionSet(&op.selection_set, root_type, Value.fromNull(self.allocator));
        try result.data.object.put(try self.allocator.dupe(u8, "data"), data);

        // Attach errors if any were collected during execution
        if (self.errors.items.len > 0) {
            var errors_list = Value.initList(self.allocator);
            errdefer errors_list.deinit();
            for (self.errors.items) |err| {
                var err_obj = Value.initObject(self.allocator);
                try err_obj.data.object.put(try self.allocator.dupe(u8, "message"), Value.fromString(self.allocator, try self.allocator.dupe(u8, err.message)));
                if (err.path) |path| {
                    var path_list = Value.initList(self.allocator);
                    errdefer path_list.deinit();
                    for (path) |segment| {
                        try path_list.data.list.append(Value.fromString(self.allocator, try self.allocator.dupe(u8, segment)));
                    }
                    try err_obj.data.object.put(try self.allocator.dupe(u8, "path"), path_list);
                }
                try errors_list.data.list.append(err_obj);
            }
            try result.data.object.put(try self.allocator.dupe(u8, "errors"), errors_list);
            self.clearErrors(); // transferred into Value
        }

        return result;
    }

    /// Execute a subscription operation and return a stream of response Values.
    /// The caller must keep the Executor alive for the lifetime of the returned stream.
    pub fn executeSubscription(self: *Executor, doc: *ast.Document) ExecutionError!schema.SubscriptionStream {
        self.document = doc;
        self.clearFragments();
        self.clearErrors();
        defer {
            self.document = null;
            self.clearFragments();
        }

        // Collect fragment definitions
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .fragment => |*frag| {
                    try self.fragments.put(try self.allocator.dupe(u8, frag.name), frag);
                },
                else => {},
            }
        }

        // Find subscription operation
        var op_def: ?*ast.OperationDefinition = null;
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .operation => |*op| {
                    if (op.op_type == .subscription) {
                        op_def = op;
                        break;
                    }
                },
                else => {},
            }
        }

        const op = op_def orelse return error.ResolverError;
        const root_type = self.schema_def.subscription_type orelse return error.ResolverError;

        // GraphQL spec: subscription must have exactly one root field
        if (op.selection_set.selections.items.len != 1) {
            return error.ResolverError;
        }

        const sub_field = switch (op.selection_set.selections.items[0]) {
            .field => |*f| f,
            else => return error.ResolverError,
        };
        const field_def = root_type.kind.object.fields.getPtr(sub_field.name) orelse return error.ResolverError;

        // Build arguments
        var args = std.StringHashMap(Value).init(self.allocator);
        errdefer {
            var aiter = args.iterator();
            while (aiter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
            args.deinit();
        }

        for (sub_field.arguments.items) |arg| {
            var arg_value = try self.coerceValue(arg.value);
            const arg_key = try self.allocator.dupe(u8, arg.name);
            errdefer self.allocator.free(arg_key);
            args.put(arg_key, arg_value) catch |err| {
                arg_value.deinit();
                self.allocator.free(arg_key);
                return err;
            };
        }

        // Fill in default values for missing arguments from schema
        var sub_def_iter = field_def.arguments.iterator();
        while (sub_def_iter.next()) |entry| {
            if (args.contains(entry.key_ptr.*)) continue;
            if (entry.value_ptr.default_value) |dv| {
                var default_clone = try dv.clone();
                errdefer default_clone.deinit();
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                args.put(key, default_clone) catch |err| {
                    default_clone.deinit();
                    self.allocator.free(key);
                    return err;
                };
            }
        }

        const subscribe_fn = field_def.subscribe orelse return error.ResolverError;
        const inner = subscribe_fn(self.context.user_data, self.allocator, Value.fromNull(self.allocator), args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResolverError,
        };

        const ctx = try self.allocator.create(SubscriptionContext);
        ctx.* = .{
            .executor = self,
            .inner = inner,
            .sub_field = sub_field,
            .field_def = field_def,
            .root_type = root_type,
            .cancelled = .init(false),
        };

        return schema.SubscriptionStream{
            .ptr = ctx,
            .vtable = &.{
                .next = subscriptionNext,
                .deinit = subscriptionDeinit,
                .cancel = subscriptionCancel,
            },
        };
    }

    const SubscriptionContext = struct {
        executor: *Executor,
        inner: schema.SubscriptionStream,
        sub_field: *ast.Field,
        field_def: *schema.Field,
        root_type: *schema.Type,
        cancelled: std.atomic.Value(bool),
    };

    fn subscriptionNext(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?Value {
        const ctx = @as(*SubscriptionContext, @ptrCast(@alignCast(ptr)));
        if (ctx.cancelled.load(.seq_cst)) return null;
        var parent_value = try ctx.inner.next(allocator) orelse return null;

        // Execute the selection set for this subscription event
        const field_type_name = ctx.field_def.field_type.innerTypeName();
        const field_type = ctx.executor.schema_def.getType(field_type_name);

        if (field_type) |ft| {
            if (ctx.sub_field.selection_set) |*fss| {
                const data = ctx.executor.executeSelectionSet(fss, ft, parent_value) catch |err| {
                    parent_value.deinit();
                    return err;
                };
                parent_value.deinit();

                var result = Value.initObject(allocator);
                errdefer result.deinit();
                try result.data.object.put(try allocator.dupe(u8, "data"), data);

                if (ctx.executor.errors.items.len > 0) {
                    var errors_list = Value.initList(allocator);
                    errdefer errors_list.deinit();
                    for (ctx.executor.errors.items) |err| {
                        var err_obj = Value.initObject(allocator);
                        try err_obj.data.object.put(try allocator.dupe(u8, "message"), Value.fromString(allocator, try allocator.dupe(u8, err.message)));
                        try errors_list.data.list.append(err_obj);
                    }
                    try result.data.object.put(try allocator.dupe(u8, "errors"), errors_list);
                    ctx.executor.clearErrors();
                }

                return result;
            }
        }

        // No selection set: return the parent value directly wrapped in data
        var result = Value.initObject(allocator);
        errdefer result.deinit();
        try result.data.object.put(try allocator.dupe(u8, "data"), parent_value);
        return result;
    }

    fn subscriptionDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const ctx = @as(*SubscriptionContext, @ptrCast(@alignCast(ptr)));
        ctx.inner.deinit(allocator);
        allocator.destroy(ctx);
    }

    fn subscriptionCancel(ptr: *anyopaque) void {
        const ctx = @as(*SubscriptionContext, @ptrCast(@alignCast(ptr)));
        ctx.cancelled.store(true, .seq_cst);
    }

    pub fn executeSelectionSet(self: *Executor, ss: *ast.SelectionSet, parent_type: *schema.Type, parent_value: Value) ExecutionError!Value {
        return self.executeSelectionSetWithPath(ss, parent_type, parent_value, &[_][]const u8{});
    }

    fn executeSelectionSetWithPath(self: *Executor, ss: *ast.SelectionSet, parent_type: *schema.Type, parent_value: Value, path_prefix: []const []const u8) ExecutionError!Value {
        var result = Value.initObject(self.allocator);
        errdefer result.deinit();

        // Merge fields with same response key (alias or name)
        var grouped_fields = std.StringHashMap(std.array_list.Managed(*ast.Field)).init(self.allocator);
        defer {
            var iter = grouped_fields.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            grouped_fields.deinit();
        }

        var visited_fragments = std.StringHashMap(void).init(self.allocator);
        defer {
            var viter = visited_fragments.iterator();
            while (viter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            visited_fragments.deinit();
        }

        try self.collectFields(ss, parent_type, &grouped_fields, &visited_fragments);

        // Alias abuse protection: limit number of distinct response keys
        if (grouped_fields.count() > 100) {
            return error.ResolverError;
        }

        // Build ordered list of fields for deterministic execution
        var keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer keys.deinit();
        var field_ptrs = std.array_list.Managed(*ast.Field).init(self.allocator);
        defer field_ptrs.deinit();

        var iter = grouped_fields.iterator();
        while (iter.next()) |entry| {
            const fields_list = entry.value_ptr.*;
            if (fields_list.items.len == 0) continue;
            try keys.append(entry.key_ptr.*);
            try field_ptrs.append(fields_list.items[0]);
        }

        // If only one field, execute sequentially
        if (field_ptrs.items.len <= 1) {
            for (field_ptrs.items, 0..) |field, i| {
                const field_path = try self.dupePath(path_prefix, keys.items[i]);
                defer self.freePath(field_path);
                const field_value = self.executeFieldWithPath(field, parent_type, parent_value, field_path) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => |e| blk: {
                        try self.recordError(e, keys.items[i], field_path);
                        const fd = parent_type.getField(field.name);
                        if (fd != null and fd.?.field_type.isNonNull()) {
                            return e; // bubble up for NonNull fields
                        }
                        break :blk Value.fromNull(self.allocator);
                    },
                };
                try result.data.object.put(try self.allocator.dupe(u8, keys.items[i]), field_value);
            }
            return result;
        }

        // Attempt concurrent execution
        const ConcurrentResult = ExecutionError || error{Canceled};
        const Future = std.Io.Future(ConcurrentResult!Value);

        var futures = std.array_list.Managed(Future).init(self.allocator);
        defer {
            for (futures.items) |*f| {
                _ = f.cancel(self.context.io) catch {};
            }
            futures.deinit();
        }

        // Pre-allocate capacity to avoid OOM after concurrent tasks start
        futures.ensureTotalCapacity(field_ptrs.items.len) catch {
            // Fallback: sequential execution for all fields
            for (field_ptrs.items, 0..) |field, i| {
                const field_path = try self.dupePath(path_prefix, keys.items[i]);
                defer self.freePath(field_path);
                const field_value = self.executeFieldWithPath(field, parent_type, parent_value, field_path) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => |e| blk: {
                        try self.recordError(e, keys.items[i], field_path);
                        const fd = parent_type.getField(field.name);
                        if (fd != null and fd.?.field_type.isNonNull()) {
                            return e;
                        }
                        break :blk Value.fromNull(self.allocator);
                    },
                };
                try result.data.object.put(try self.allocator.dupe(u8, keys.items[i]), field_value);
            }
            return result;
        };

        var all_concurrent = true;
        for (field_ptrs.items, 0..) |field, i| {
            const task_path = try self.dupePath(path_prefix, keys.items[i]);
            const future = std.Io.concurrent(self.context.io, executeFieldTaskWithPath, .{ self, field, parent_type, parent_value, task_path }) catch {
                self.freePath(task_path);
                all_concurrent = false;
                break;
            };
            // Safe: capacity was pre-allocated; task_path is now owned by the future
            futures.appendAssumeCapacity(future);
        }

        if (all_concurrent and futures.items.len == field_ptrs.items.len) {
            for (futures.items, 0..) |*future, i| {
                const field_value = future.await(self.context.io) catch |err| switch (err) {
                    error.Canceled => blk: {
                        const field_path = try self.dupePath(path_prefix, keys.items[i]);
                        defer self.freePath(field_path);
                        try self.recordError(error.ResolverError, keys.items[i], field_path);
                        const fd = parent_type.getField(field_ptrs.items[i].name);
                        if (fd != null and fd.?.field_type.isNonNull()) {
                            return error.ResolverError;
                        }
                        break :blk Value.fromNull(self.allocator);
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |e| blk: {
                        const field_path = try self.dupePath(path_prefix, keys.items[i]);
                        defer self.freePath(field_path);
                        try self.recordError(e, keys.items[i], field_path);
                        const fd = parent_type.getField(field_ptrs.items[i].name);
                        if (fd != null and fd.?.field_type.isNonNull()) {
                            return e;
                        }
                        break :blk Value.fromNull(self.allocator);
                    },
                };
                try result.data.object.put(try self.allocator.dupe(u8, keys.items[i]), field_value);
            }
            return result;
        }

        // Fallback: cancel any started futures, then execute all fields sequentially
        for (futures.items) |*f| {
            _ = f.cancel(self.context.io) catch {};
            _ = f.await(self.context.io) catch {};
        }
        futures.clearRetainingCapacity();

        for (field_ptrs.items, 0..) |field, i| {
            const field_path = try self.dupePath(path_prefix, keys.items[i]);
            defer self.freePath(field_path);
            const field_value = self.executeFieldWithPath(field, parent_type, parent_value, field_path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => |e| blk: {
                    try self.recordError(e, keys.items[i], field_path);
                    const fd = parent_type.getField(field.name);
                    if (fd != null and fd.?.field_type.isNonNull()) {
                        return e;
                    }
                    break :blk Value.fromNull(self.allocator);
                },
            };
            try result.data.object.put(try self.allocator.dupe(u8, keys.items[i]), field_value);
        }

        return result;
    }

    fn executeSubSelection(self: *Executor, ss: *ast.SelectionSet, field_def: schema.Field, parent_value: Value, path: []const []const u8) ExecutionError!Value {
        const field_type_name = field_def.field_type.innerTypeName();
        const field_type = self.schema_def.getType(field_type_name);
        if (field_type == null) {
            const clone = try parent_value.clone();
            return clone;
        }

        // Unwrap NonNull to check for list type (handles [T!]! and [T!] patterns)
        const outer_is_non_null = field_def.field_type.isNonNull();
        const list_elem_type = blk: {
            var t = field_def.field_type;
            if (t.isNonNull()) t = t.kind.non_null.*;
            if (t.isList()) break :blk t.kind.list.*;
            break :blk null;
        };
        if (list_elem_type) |elem_type| {
            // Execute selection set per list element.
            // For [T!] (non-null element), a null element must bubble to null the whole list.
            const elem_non_null = elem_type.kind == .non_null;
            var results = Value.initList(self.allocator);
            errdefer results.deinit();
            if (parent_value.data == .list) {
                for (parent_value.data.list.items) |*item| {
                    const item_result = self.executeSelectionSetWithPath(ss, field_type.?, item.*, path) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => |e| blk: {
                            try self.recordError(e, field_def.name, path);
                            if (elem_non_null) {
                                results.deinit();
                                // If outer type is also non-null, bubble further
                                if (outer_is_non_null) return error.NullValueForNonNull;
                                return Value.fromNull(self.allocator);
                            }
                            break :blk Value.fromNull(self.allocator);
                        },
                    };
                    try results.data.list.append(item_result);
                }
            }
            return results;
        }

        // Object sub-selection
        return self.executeSelectionSetWithPath(ss, field_type.?, parent_value, path);
    }

    fn executeFieldTaskWithPath(executor: *Executor, field: *ast.Field, parent_type: *schema.Type, parent_value: Value, path: []const []const u8) (ExecutionError || error{Canceled})!Value {
        defer executor.freePath(path);
        return executor.executeFieldWithPath(field, parent_type, parent_value, path);
    }

    fn recordError(self: *Executor, err: anyerror, field_name: []const u8, path: []const []const u8) std.mem.Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.allocator, "Error in field '{s}': {s}", .{ field_name, @errorName(err) });
        errdefer self.allocator.free(msg);

        // Copy path segments
        var path_copy: ?[]const []const u8 = null;
        if (path.len > 0) {
            const segments = try self.allocator.alloc([]const u8, path.len);
            for (path, 0..) |segment, i| {
                segments[i] = try self.allocator.dupe(u8, segment);
            }
            path_copy = segments;
        }

        try self.errors.append(.{ .message = msg, .path = path_copy });
        if (self.hooks.on_error) |hook| {
            hook(self.context.user_data, msg);
        }
    }

    fn doesFragmentTypeApply(self: *Executor, fragment_type: *schema.Type, parent_type: *schema.Type) bool {
        _ = self;
        if (std.mem.eql(u8, fragment_type.name, parent_type.name)) return true;

        // If parent is object and fragment type is interface that parent implements
        if (parent_type.isObject() and fragment_type.isInterface()) {
            for (parent_type.kind.object.interfaces.items) |iface| {
                if (std.mem.eql(u8, iface, fragment_type.name)) return true;
            }
        }

        // If parent is interface and fragment type is object that implements the interface
        if (parent_type.isInterface() and fragment_type.isObject()) {
            for (fragment_type.kind.object.interfaces.items) |iface| {
                if (std.mem.eql(u8, iface, parent_type.name)) return true;
            }
        }

        // If fragment type is union and parent is a member
        if (fragment_type.isUnion()) {
            for (fragment_type.kind.union_type.possible_types.items) |pt| {
                if (std.mem.eql(u8, pt, parent_type.name)) return true;
            }
        }

        // If parent is union and fragment type is a member
        if (parent_type.isUnion()) {
            for (parent_type.kind.union_type.possible_types.items) |pt| {
                if (std.mem.eql(u8, pt, fragment_type.name)) return true;
            }
        }

        return false;
    }

    fn shouldInclude(self: *Executor, directives: std.array_list.Managed(ast.Directive)) ExecutionError!bool {
        for (directives.items) |dir| {
            if (std.mem.eql(u8, dir.name, "skip")) {
                for (dir.arguments.items) |arg| {
                    if (std.mem.eql(u8, arg.name, "if")) {
                        var val = try self.coerceValue(arg.value);
                        defer val.deinit();
                        if (val.data == .boolean and val.data.boolean) return false;
                    }
                }
            } else if (std.mem.eql(u8, dir.name, "include")) {
                for (dir.arguments.items) |arg| {
                    if (std.mem.eql(u8, arg.name, "if")) {
                        var val = try self.coerceValue(arg.value);
                        defer val.deinit();
                        if (val.data == .boolean and !val.data.boolean) return false;
                    }
                }
            }
        }
        return true;
    }

    fn collectFields(self: *Executor, ss: *ast.SelectionSet, parent_type: *schema.Type, grouped: *std.StringHashMap(std.array_list.Managed(*ast.Field)), visited_fragments: *std.StringHashMap(void)) ExecutionError!void {
        for (ss.selections.items) |*sel| {
            switch (sel.*) {
                .field => |*field| {
                    if (!try self.shouldInclude(field.directives)) continue;
                    const response_key = field.alias orelse field.name;
                    const gop = try grouped.getOrPut(response_key);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = std.array_list.Managed(*ast.Field).init(self.allocator);
                    }
                    try gop.value_ptr.append(field);
                },
                .fragment_spread => |*fs| {
                    if (!try self.shouldInclude(fs.directives)) continue;
                    if (visited_fragments.contains(fs.name)) continue;
                    try visited_fragments.put(try self.allocator.dupe(u8, fs.name), {});

                    const frag = self.fragments.get(fs.name);
                    if (frag == null) continue; // Validation should catch undefined fragments

                    const frag_type = self.schema_def.getType(frag.?.type_condition.name);
                    if (frag_type == null) continue;

                    if (self.doesFragmentTypeApply(frag_type.?, parent_type)) {
                        try self.collectFields(&frag.?.selection_set, parent_type, grouped, visited_fragments);
                    }
                },
                .inline_fragment => |*ifrag| {
                    if (!try self.shouldInclude(ifrag.directives)) continue;
                    if (ifrag.type_condition) |tc| {
                        const tc_type = self.schema_def.getType(tc.name);
                        if (tc_type == null) continue;
                        if (!self.doesFragmentTypeApply(tc_type.?, parent_type)) continue;
                    }
                    try self.collectFields(&ifrag.selection_set, parent_type, grouped, visited_fragments);
                },
            }
        }
    }

    pub fn executeField(self: *Executor, field: *ast.Field, parent_type: *schema.Type, parent_value: Value) ExecutionError!Value {
        return self.executeFieldWithPath(field, parent_type, parent_value, &[_][]const u8{});
    }

    fn executeFieldWithPath(self: *Executor, field: *ast.Field, parent_type: *schema.Type, parent_value: Value, path: []const []const u8) ExecutionError!Value {
        // GraphQL introspection meta-fields
        if (std.mem.eql(u8, field.name, "__typename")) {
            // If the parent value has an explicit __typename (set by resolver for
            // interface/union runtime types), use it. Otherwise fall back to schema type name.
            if (parent_value.data == .object) {
                if (parent_value.data.object.get("__typename")) |tn| {
                    if (tn.data == .string) {
                        return Value.fromString(self.allocator, try self.allocator.dupe(u8, tn.data.string));
                    }
                }
            }
            return Value.fromString(self.allocator, try self.allocator.dupe(u8, parent_type.name));
        }
        if (std.mem.eql(u8, field.name, "__schema") and self.schema_def.query_type == parent_type) {
            return try Introspection.buildSchemaValue(self.allocator, self.schema_def);
        }
        if (std.mem.eql(u8, field.name, "__type") and self.schema_def.query_type == parent_type) {
            var type_name: ?[]const u8 = null;
            for (field.arguments.items) |arg| {
                if (std.mem.eql(u8, arg.name, "name")) {
                    switch (arg.value) {
                        .string_value => |s| type_name = s,
                        .variable => |var_name| {
                            if (self.context.variables.get(var_name)) |v| {
                                if (v.data == .string) type_name = v.data.string;
                            }
                        },
                        else => {},
                    }
                }
            }
            if (type_name) |tn| {
                if (self.schema_def.getType(tn)) |t| {
                    return try Introspection.buildTypeValue(self.allocator, self.schema_def, t);
                }
            }
            return Value.fromNull(self.allocator);
        }

        const field_def = parent_type.getField(field.name);
        if (field_def == null) {
            return error.InvalidField;
        }

        // Auth / pre-execute hook
        if (self.hooks.before_field_execute) |hook| {
            const allowed = hook(self.context.user_data, field.name);
            if (!allowed) {
                if (self.hooks.after_field_execute) |after| {
                    after(self.context.user_data, field.name, true, 0);
                }
                return error.ResolverError;
            }
        }

        // Field-level authorization
        if (field_def.?.required_role) |role| {
            const allowed = if (self.hooks.hasRole) |hasRole|
                hasRole(self.context.user_data, role)
            else
                false;
            if (!allowed) {
                if (self.hooks.after_field_execute) |after| {
                    after(self.context.user_data, field.name, true, 0);
                }
                return error.Unauthorized;
            }
        }

        const start = Io.Clock.Timestamp.now(self.context.io, .real);
        var had_error = false;
        defer {
            if (self.hooks.after_field_execute) |after| {
                const end = Io.Clock.Timestamp.now(self.context.io, .real);
                const duration = end.raw.durationTo(start.raw);
                const duration_ns: u64 = @intCast(@max(0, duration.nanoseconds));
                after(self.context.user_data, field.name, had_error, duration_ns);
            }
        }

        // Build arguments
        var args = std.StringHashMap(Value).init(self.allocator);
        defer {
            var aiter = args.iterator();
            while (aiter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
            args.deinit();
        }

        for (field.arguments.items) |arg| {
            var arg_value = try self.coerceValue(arg.value);
            const arg_key = try self.allocator.dupe(u8, arg.name);
            errdefer self.allocator.free(arg_key);
            args.put(arg_key, arg_value) catch |err| {
                arg_value.deinit();
                self.allocator.free(arg_key);
                return err;
            };
        }

        // Fill in default values for missing arguments from schema
        var def_iter = field_def.?.arguments.iterator();
        while (def_iter.next()) |entry| {
            if (args.contains(entry.key_ptr.*)) continue;
            if (entry.value_ptr.default_value) |dv| {
                var default_clone = try dv.clone();
                errdefer default_clone.deinit();
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                args.put(key, default_clone) catch |err| {
                    default_clone.deinit();
                    self.allocator.free(key);
                    return err;
                };
            }
        }

        // Call resolver if present
        if (field_def.?.resolve) |resolve_fn| {
            var resolved = resolve_fn(
                self.context.user_data orelse &self.context,
                self.allocator,
                parent_value,
                args,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    had_error = true;
                    return error.OutOfMemory;
                },
                error.PermissionDenied,
                error.NotFound,
                error.Timeout,
                error.InvalidInput,
                error.ExternalServiceError,
                error.RateLimited,
                error.Unauthorized => |e| {
                    had_error = true;
                    return e;
                },
                else => {
                    had_error = true;
                    return error.ResolverError;
                },
            };

            // Handle sub-selection
            if (field.selection_set) |*fss| {
                const child_path = try self.dupePath(path, field.name);
                defer self.freePath(child_path);
                const result = self.executeSubSelection(fss, field_def.?.*, resolved, child_path) catch |err| {
                    resolved.deinit();
                    had_error = true;
                    if (field_def.?.field_type.isNonNull()) {
                        return err; // bubble up
                    }
                    return Value.fromNull(self.allocator);
                };
                resolved.deinit();
                return result;
            }
            return resolved;
        }

        // No resolver: try to extract from parent value
        if (field.selection_set) |*fss| {
            const child_value = if (parent_value.data == .object)
                parent_value.data.object.get(field.name) orelse null
            else
                null;
            const child_path = try self.dupePath(path, field.name);
            defer self.freePath(child_path);
            const result = self.executeSubSelection(fss, field_def.?.*, child_value orelse Value.fromNull(self.allocator), child_path) catch |err| {
                if (field_def.?.field_type.isNonNull()) {
                    return err;
                }
                return Value.fromNull(self.allocator);
            };
            return result;
        }

        // Scalar field without resolver: extract from parent object
        if (parent_value.data == .object) {
            if (parent_value.data.object.get(field.name)) |v| {
                const result = try v.clone();
                return result;
            }
        }
        return Value.fromNull(self.allocator);
    }

    fn coerceValue(self: *Executor, val: ast.AstValue) ExecutionError!Value {
        switch (val) {
            .variable => |name| {
                if (self.context.variables.get(name)) |v| {
                    return try v.clone();
                }
                return Value.fromNull(self.allocator);
            },
            .int_value => |text| {
                const i = std.fmt.parseInt(i64, text, 10) catch return error.InvalidArgument;
                return Value.fromInt(self.allocator, i);
            },
            .float_value => |text| {
                const f = std.fmt.parseFloat(f64, text) catch return error.InvalidArgument;
                return Value.fromFloat(self.allocator, f);
            },
            .string_value => |text| {
                return Value.fromString(self.allocator, try self.allocator.dupe(u8, text));
            },
            .boolean_value => |b| return Value.fromBool(self.allocator, b),
            .null_value => return Value.fromNull(self.allocator),
            .enum_value => |text| return Value.fromEnum(self.allocator, try self.allocator.dupe(u8, text)),
            .list_value => |list| {
                var result = Value.initList(self.allocator);
                errdefer result.deinit();
                for (list.items) |item| {
                    try result.data.list.append(try self.coerceValue(item));
                }
                return result;
            },
            .object_value => |obj| {
                var result = Value.initObject(self.allocator);
                errdefer result.deinit();
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try result.data.object.put(try self.allocator.dupe(u8, entry.key_ptr.*), try self.coerceValue(entry.value_ptr.*));
                }
                return result;
            },
        }
    }
};

test "executor basic" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "{ hello }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    try std.testing.expectEqualStrings("world", result.data.object.get("data").?.data.object.get("hello").?.data.string);
}

test "executor with fragment spread" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };

    var user_type = try allocator.create(schema.Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var name_field = schema.Field.init(allocator, "name", schema.TypeRef.named("String"));
    name_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "Alice"));
        }
    }.resolve;
    try user_type.kind.object.fields.put(try allocator.dupe(u8, "name"), name_field);

    var user_field = schema.Field.init(allocator, "user", schema.TypeRef.named("User"));
    user_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromNull(alloc);
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "user"), user_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("User", user_type);

    const source =
        \\{ user { ...userFields } }
        \\fragment userFields on User { name }
    ;
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    const data = result.data.object.get("data").?.data.object;
    const user_obj = data.get("user").?.data.object;
    try std.testing.expectEqualStrings("Alice", user_obj.get("name").?.data.string);
}

test "executor field error returns partial data" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };

    var ok_field = schema.Field.init(allocator, "ok", schema.TypeRef.named("String"));
    ok_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "yes"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "ok"), ok_field);

    var fail_field = schema.Field.init(allocator, "fail", schema.TypeRef.named("String"));
    fail_field.resolve = struct {
        fn resolve(_: ?*anyopaque, _: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return error.SomeFailure;
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "fail"), fail_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "{ ok fail }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    // Use a real Io backend for concurrent field execution
    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    const data = result.data.object.get("data").?.data.object;
    try std.testing.expectEqualStrings("yes", data.get("ok").?.data.string);
    try std.testing.expect(data.get("fail").?.data == .null);

    // Errors should be attached
    const errors = result.data.object.get("errors").?.data.list;
    try std.testing.expect(errors.items.len > 0);
}

test "executor operationName selection" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var a_field = schema.Field.init(allocator, "a", schema.TypeRef.named("String"));
    a_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "A"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "a"), a_field);
    var b_field = schema.Field.init(allocator, "b", schema.TypeRef.named("String"));
    b_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "B"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "b"), b_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source =
        \\query OpA { a }
        \\query OpB { b }
    ;
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result_a = try executor.executeNamed(&doc, "OpA");
    defer result_a.deinit();
    try std.testing.expectEqualStrings("A", result_a.data.object.get("data").?.data.object.get("a").?.data.string);

    var result_b = try executor.executeNamed(&doc, "OpB");
    defer result_b.deinit();
    try std.testing.expectEqualStrings("B", result_b.data.object.get("data").?.data.object.get("b").?.data.string);
}

test "executor inline fragment with type condition" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };

    var user_type = try allocator.create(schema.Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var name_field = schema.Field.init(allocator, "name", schema.TypeRef.named("String"));
    name_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "Alice"));
        }
    }.resolve;
    try user_type.kind.object.fields.put(try allocator.dupe(u8, "name"), name_field);

    var user_field = schema.Field.init(allocator, "user", schema.TypeRef.named("User"));
    user_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            var user = Value.initObject(alloc);
            try user.data.object.put(try alloc.dupe(u8, "name"), Value.fromString(alloc, try alloc.dupe(u8, "Alice")));
            return user;
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "user"), user_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("User", user_type);

    const source =
        \\{ user { ... on User { name } } }
    ;
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    const data = result.data.object.get("data").?.data.object;
    const user_obj = data.get("user").?.data.object;
    try std.testing.expectEqualStrings("Alice", user_obj.get("name").?.data.string);
}

test "executor variables substitution" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var greet_field = schema.Field.init(allocator, "greet", schema.TypeRef.named("String"));
    greet_field.resolve = struct {
        fn resolve(ctx: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            const exec_ctx = @as(*Context, @ptrCast(@alignCast(ctx.?)));
            const name = exec_ctx.variables.get("name") orelse return Value.fromString(alloc, try alloc.dupe(u8, "stranger"));
            const greeting = try std.fmt.allocPrint(alloc, "Hello, {s}!", .{name.data.string});
            return Value.fromString(alloc, greeting);
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "greet"), greet_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query($name: String) { greet }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    // Set variable
    var variables = std.StringHashMap(Value).init(allocator);
    defer {
        var viter = variables.iterator();
        while (viter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        variables.deinit();
    }
    try variables.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, "World")));
    try executor.setVariables(variables);

    var result = try executor.execute(&doc);
    defer result.deinit();

    const data = result.data.object.get("data").?.data.object;
    try std.testing.expectEqualStrings("Hello, World!", data.get("greet").?.data.string);
}

test "executor hooks" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "{ hello }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var hook_called = false;
    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();
    executor.hooks = .{
        .before_field_execute = struct {
            fn hook(ctx: ?*anyopaque, field_name: []const u8) bool {
                _ = field_name;
                const called = @as(*bool, @ptrCast(@alignCast(ctx.?)));
                called.* = true;
                return true;
            }
        }.hook,
    };
    executor.context.user_data = &hook_called;

    var result = try executor.execute(&doc);
    defer result.deinit();

    try std.testing.expect(hook_called);
}

test "executor subscription stream" {
    const allocator = std.testing.allocator;

    // Define a simple counter stream that yields 3 integers
    const CounterStream = struct {
        max: i64,
        current: i64,

        fn next(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?Value {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));
            if (ctx.current >= ctx.max) return null;
            const val = ctx.current;
            ctx.current += 1;
            return Value.fromInt(alloc, val);
        }

        fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));
            alloc.destroy(ctx);
        }
    };

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };

    const sub_type = try allocator.create(schema.Type);
    sub_type.* = .{
        .name = "Subscription",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var counter_field = schema.Field.init(allocator, "counter", schema.TypeRef.named("Int"));
    counter_field.subscribe = struct {
        fn subscribe(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!schema.SubscriptionStream {
            const ctx = try alloc.create(CounterStream);
            ctx.* = .{ .max = 3, .current = 0 };
            return schema.SubscriptionStream{
                .ptr = ctx,
                .vtable = &.{
                    .next = CounterStream.next,
                    .deinit = CounterStream.deinit,
                },
            };
        }
    }.subscribe;
    try sub_type.kind.object.fields.put(try allocator.dupe(u8, "counter"), counter_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("Subscription", sub_type);
    schema_def.subscription_type = sub_type;

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var parser = @import("parser.zig").Parser.init(allocator, "subscription { counter }") catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var stream = try executor.executeSubscription(&doc);
    defer stream.deinit(allocator);

    var expected: i64 = 0;
    while (true) {
        var event = try stream.next(allocator) orelse break;
        defer event.deinit();

        try std.testing.expect(event.data == .object);
        const data = event.data.object.get("data") orelse {
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(data.data == .int);
        try std.testing.expectEqual(expected, data.data.int);
        expected += 1;
    }
    try std.testing.expectEqual(3, expected);
}

test "executor subscription cancel" {
    const allocator = std.testing.allocator;

    const InfiniteStream = struct {
        current: i64,

        fn next(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror!?Value {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));
            const val = ctx.current;
            ctx.current += 1;
            return Value.fromInt(alloc, val);
        }

        fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ptr)));
            alloc.destroy(ctx);
        }
    };

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };

    const sub_type = try allocator.create(schema.Type);
    sub_type.* = .{
        .name = "Subscription",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var counter_field = schema.Field.init(allocator, "counter", schema.TypeRef.named("Int"));
    counter_field.subscribe = struct {
        fn subscribe(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!schema.SubscriptionStream {
            const ctx = try alloc.create(InfiniteStream);
            ctx.* = .{ .current = 0 };
            return schema.SubscriptionStream{
                .ptr = ctx,
                .vtable = &.{
                    .next = InfiniteStream.next,
                    .deinit = InfiniteStream.deinit,
                },
            };
        }
    }.subscribe;
    try sub_type.kind.object.fields.put(try allocator.dupe(u8, "counter"), counter_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("Subscription", sub_type);
    schema_def.subscription_type = sub_type;

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var parser = @import("parser.zig").Parser.init(allocator, "subscription { counter }") catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var stream = try executor.executeSubscription(&doc);
    defer stream.deinit(allocator);

    // Consume one event
    var event = try stream.next(allocator) orelse {
        return error.TestUnexpectedResult;
    };
    defer event.deinit();
    try std.testing.expect(event.data == .object);

    // Cancel the stream
    stream.cancel();

    // Next call should return null because executor checks cancelled flag
    const next_event = try stream.next(allocator);
    try std.testing.expect(next_event == null);
}

test "executor @skip directive" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    // Skip when $skip is true
    var executor1 = Executor.init(allocator, &schema_def, backend.io());
    defer executor1.deinit();
    var vars1 = std.StringHashMap(Value).init(allocator);
    defer {
        var vit = vars1.iterator();
        while (vit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        vars1.deinit();
    }
    try vars1.put(try allocator.dupe(u8, "skip"), Value.fromBool(allocator, true));
    try executor1.setVariables(vars1);

    var parser1 = @import("parser.zig").Parser.init(allocator, "{ hello @skip(if: $skip) }") catch unreachable;
    defer parser1.deinit();
    var doc1 = try parser1.parseDocument();
    defer doc1.deinit();

    var result1 = try executor1.execute(&doc1);
    defer result1.deinit();
    const data1 = result1.data.object.get("data") orelse return error.TestUnexpectedResult;
    try std.testing.expect(data1.data.object.get("hello") == null);

    // Include when $skip is false
    var executor2 = Executor.init(allocator, &schema_def, backend.io());
    defer executor2.deinit();
    var vars2 = std.StringHashMap(Value).init(allocator);
    defer {
        var vit = vars2.iterator();
        while (vit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        vars2.deinit();
    }
    try vars2.put(try allocator.dupe(u8, "skip"), Value.fromBool(allocator, false));
    try executor2.setVariables(vars2);

    var parser2 = @import("parser.zig").Parser.init(allocator, "{ hello @skip(if: $skip) }") catch unreachable;
    defer parser2.deinit();
    var doc2 = try parser2.parseDocument();
    defer doc2.deinit();

    var result2 = try executor2.execute(&doc2);
    defer result2.deinit();
    const data2 = result2.data.object.get("data") orelse return error.TestUnexpectedResult;
    const hello2 = data2.data.object.get("hello") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, hello2.data.string, "world"));
}

test "executor @skip directive direct selection set" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var vars = std.StringHashMap(Value).init(allocator);
    defer {
        var vit = vars.iterator();
        while (vit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        vars.deinit();
    }
    try vars.put(try allocator.dupe(u8, "skip"), Value.fromBool(allocator, false));
    try executor.setVariables(vars);

    var parser = @import("parser.zig").Parser.init(allocator, "{ hello @skip(if: $skip) }") catch unreachable;
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const def = &doc.definitions.items[0];
    switch (def.*) {
        .operation => |*op| {
            var result = try executor.executeSelectionSet(&op.selection_set, query_type, Value.fromNull(allocator));
            defer result.deinit();
            const hello = result.data.object.get("hello") orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.eql(u8, hello.data.string, "world"));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "executor @include directive" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    // Exclude when $inc is false
    var executor1 = Executor.init(allocator, &schema_def, backend.io());
    defer executor1.deinit();
    var vars1 = std.StringHashMap(Value).init(allocator);
    defer {
        var vit = vars1.iterator();
        while (vit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        vars1.deinit();
    }
    try vars1.put(try allocator.dupe(u8, "inc"), Value.fromBool(allocator, false));
    try executor1.setVariables(vars1);

    var parser1 = @import("parser.zig").Parser.init(allocator, "{ hello @include(if: $inc) }") catch unreachable;
    defer parser1.deinit();
    var doc1 = try parser1.parseDocument();
    defer doc1.deinit();

    var result1 = try executor1.execute(&doc1);
    defer result1.deinit();
    const data1 = result1.data.object.get("data") orelse return error.TestUnexpectedResult;
    try std.testing.expect(data1.data.object.get("hello") == null);

    // Include when $inc is true
    var executor2 = Executor.init(allocator, &schema_def, backend.io());
    defer executor2.deinit();
    var vars2 = std.StringHashMap(Value).init(allocator);
    defer {
        var vit = vars2.iterator();
        while (vit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        vars2.deinit();
    }
    try vars2.put(try allocator.dupe(u8, "inc"), Value.fromBool(allocator, true));
    try executor2.setVariables(vars2);

    var parser2 = @import("parser.zig").Parser.init(allocator, "{ hello @include(if: $inc) }") catch unreachable;
    defer parser2.deinit();
    var doc2 = try parser2.parseDocument();
    defer doc2.deinit();

    var result2 = try executor2.execute(&doc2);
    defer result2.deinit();
    const data2 = result2.data.object.get("data") orelse return error.TestUnexpectedResult;
    const hello2 = data2.data.object.get("hello") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, hello2.data.string, "world"));
}

test "executor __typename from schema type" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{ .name = "Query", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            return Value.fromString(alloc, try alloc.dupe(u8, "world"));
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var parser = try @import("parser.zig").Parser.init(allocator, "{ __typename }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    const data = result.data.object.get("data").?.data.object;
    try std.testing.expectEqualStrings("Query", data.get("__typename").?.data.string);
}

test "executor __typename from runtime value" {
    const allocator = std.testing.allocator;

    const node_type = try allocator.create(schema.Type);
    node_type.* = .{ .name = "Node", .kind = .{ .interface = schema.InterfaceType.init(allocator) } };

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{ .name = "Query", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    var node_field = schema.Field.init(allocator, "node", schema.TypeRef.named("Node"));
    node_field.resolve = struct {
        fn resolve(_: ?*anyopaque, alloc: std.mem.Allocator, _: Value, _: std.StringHashMap(Value)) anyerror!Value {
            var obj = Value.initObject(alloc);
            try obj.data.object.put(try alloc.dupe(u8, "__typename"), Value.fromString(alloc, try alloc.dupe(u8, "User")));
            try obj.data.object.put(try alloc.dupe(u8, "name"), Value.fromString(alloc, try alloc.dupe(u8, "Alice")));
            return obj;
        }
    }.resolve;
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "node"), node_field);

    var schema_def = schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("Node", node_type);

    var parser = try @import("parser.zig").Parser.init(allocator, "{ node { __typename name } }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    const IoBackend = if (@import("builtin").os.tag == .linux) std.Io.Uring else std.Io.Threaded;
    var backend = IoBackend.init(allocator, .{});
    defer backend.deinit();

    var executor = Executor.init(allocator, &schema_def, backend.io());
    defer executor.deinit();

    var result = try executor.execute(&doc);
    defer result.deinit();

    const node = result.data.object.get("data").?.data.object.get("node").?.data.object;
    try std.testing.expectEqualStrings("User", node.get("__typename").?.data.string);
}

