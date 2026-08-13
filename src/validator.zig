const std = @import("std");
const ast = @import("ast.zig");
const schema = @import("schema.zig");

pub const ValidationError = struct {
    message: []const u8,
    line: ?usize = null,
    col: ?usize = null,
};

pub const ValidationResult = struct {
    errors: std.array_list.Managed(ValidationError),

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{ .errors = std.array_list.Managed(ValidationError).init(allocator) };
    }

    pub fn deinit(self: *ValidationResult) void {
        self.errors.deinit();
    }

    pub fn isValid(self: ValidationResult) bool {
        return self.errors.items.len == 0;
    }

    pub fn addError(self: *ValidationResult, message: []const u8, line: ?usize, col: ?usize) !void {
        try self.errors.append(.{ .message = message, .line = line, .col = col });
    }
};

pub const Validator = struct {
    allocator: std.mem.Allocator,
    schema_def: *schema.Schema,
    result: ValidationResult,
    fragments: std.StringHashMap(*ast.FragmentDefinition),
    variables: std.StringHashMap(*ast.Type),

    pub fn init(allocator: std.mem.Allocator, schema_def: *schema.Schema) Validator {
        return .{
            .allocator = allocator,
            .schema_def = schema_def,
            .result = ValidationResult.init(allocator),
            .fragments = std.StringHashMap(*ast.FragmentDefinition).init(allocator),
            .variables = std.StringHashMap(*ast.Type).init(allocator),
        };
    }

    pub fn deinit(self: *Validator) void {
        self.result.deinit();
        self.fragments.deinit();
        var var_iter = self.variables.iterator();
        while (var_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.variables.deinit();
    }

    pub fn validate(self: *Validator, doc: *ast.Document) !ValidationResult {
        // Deinit any previous result to avoid leaking when the validator is reused.
        self.result.deinit();
        self.result = ValidationResult.init(self.allocator);

        // Clear stale state from previous validation (prevents UAF on reuse)
        self.fragments.clearRetainingCapacity();

        // Collect fragments
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .fragment => |*frag| {
                    if (self.fragments.contains(frag.name)) {
                        try self.result.addError("Fragment name must be unique", frag.line, frag.col);
                    } else {
                        try self.fragments.put(frag.name, frag);
                    }
                },
                else => {},
            }
        }

        // Detect fragment cycles
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var viter = visited.iterator();
            while (viter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            visited.deinit();
        }

        var frag_iter = self.fragments.iterator();
        while (frag_iter.next()) |entry| {
            try self.detectFragmentCycles(entry.key_ptr.*, entry.value_ptr.*, &visited);
        }

        // Validate definitions. Fragments are validated on-demand when spread
        // from operations, so that variable references resolve correctly.
        var validated_fragments = std.StringHashMap(void).init(self.allocator);
        defer {
            var vf_iter = validated_fragments.iterator();
            while (vf_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            validated_fragments.deinit();
        }

        // Operation-level rules: UniqueOperationNames (§5.2.1.1) and
        // LoneAnonymousOperation (§5.2.2.1).
        try self.validateOperationNames(doc);

        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .operation => |*op| try self.validateOperation(op, &validated_fragments),
                .fragment => {}, // validated on-demand from operations
            }
        }

        // NoUnusedFragments (§5.5.1.4): every fragment must be reachable from
        // at least one operation.
        try self.validateUnusedFragments(doc);

        return self.result;
    }

    /// §5.2.1.1 UniqueOperationNames + §5.2.2.1 LoneAnonymousOperation.
    fn validateOperationNames(self: *Validator, doc: *ast.Document) ValidateError!void {
        var op_names = std.StringHashMap(void).init(self.allocator);
        defer {
            var iter = op_names.keyIterator();
            while (iter.next()) |k| self.allocator.free(k.*);
            op_names.deinit();
        }

        var op_count: usize = 0;
        var has_anonymous = false;
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .operation => |*op| {
                    op_count += 1;
                    if (op.name) |name| {
                        if (op_names.contains(name)) {
                            try self.result.addError("Operation name must be unique", op.line, op.col);
                        } else {
                            try op_names.put(try self.allocator.dupe(u8, name), {});
                        }
                    } else {
                        has_anonymous = true;
                    }
                },
                else => {},
            }
        }

        // LoneAnonymousOperation: an anonymous operation must be the only
        // operation in the document.
        if (has_anonymous and op_count > 1) {
            for (doc.definitions.items) |*def| {
                switch (def.*) {
                    .operation => |*op| {
                        if (op.name == null) {
                            try self.result.addError("An anonymous operation must be the only defined operation", op.line, op.col);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// §5.5.1.4 NoUnusedFragments: every fragment must be reachable from at
    /// least one operation (directly or transitively).
    fn validateUnusedFragments(self: *Validator, doc: *ast.Document) ValidateError!void {
        var used = std.StringHashMap(void).init(self.allocator);
        defer {
            var iter = used.keyIterator();
            while (iter.next()) |k| self.allocator.free(k.*);
            used.deinit();
        }

        // Mark fragments reachable from operations (transitively).
        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .operation => |*op| try self.markUsedFragments(&op.selection_set, &used),
                else => {},
            }
        }

        for (doc.definitions.items) |*def| {
            switch (def.*) {
                .fragment => |*frag| {
                    if (!used.contains(frag.name)) {
                        try self.result.addError("Fragment is never used", frag.line, frag.col);
                    }
                },
                else => {},
            }
        }
    }

    fn markUsedFragments(self: *Validator, ss: *ast.SelectionSet, used: *std.StringHashMap(void)) ValidateError!void {
        for (ss.selections.items) |*sel| {
            switch (sel.*) {
                .fragment_spread => |*fs| {
                    if (used.contains(fs.name)) continue;
                    try used.put(try self.allocator.dupe(u8, fs.name), {});
                    if (self.fragments.get(fs.name)) |frag| {
                        try self.markUsedFragments(&frag.selection_set, used);
                    }
                },
                .inline_fragment => |*ifrag| try self.markUsedFragments(&ifrag.selection_set, used),
                .field => |*field| {
                    if (field.selection_set) |*fss| try self.markUsedFragments(fss, used);
                },
            }
        }
    }

    fn detectFragmentCycles(self: *Validator, frag_name: []const u8, frag: *ast.FragmentDefinition, visited: *std.StringHashMap(void)) ValidateError!void {
        if (visited.contains(frag_name)) {
            try self.result.addError("Fragment spread forms a cycle", null, null);
            return;
        }

        const key = try self.allocator.dupe(u8, frag_name);
        try visited.put(key, {});
        defer {
            _ = visited.remove(key);
            self.allocator.free(key);
        }

        try self.detectFragmentCyclesInSelectionSet(&frag.selection_set, visited);
    }

    fn detectFragmentCyclesInSelectionSet(self: *Validator, ss: *ast.SelectionSet, visited: *std.StringHashMap(void)) ValidateError!void {
        for (ss.selections.items) |*sel| {
            switch (sel.*) {
                .fragment_spread => |*fs| {
                    if (self.fragments.get(fs.name)) |target_frag| {
                        try self.detectFragmentCycles(fs.name, target_frag, visited);
                    }
                },
                .inline_fragment => |*ifrag| {
                    try self.detectFragmentCyclesInSelectionSet(&ifrag.selection_set, visited);
                },
                .field => |*field| {
                    if (field.selection_set) |*fss| {
                        try self.detectFragmentCyclesInSelectionSet(fss, visited);
                    }
                },
            }
        }
    }

    fn validateOperation(self: *Validator, op: *ast.OperationDefinition, validated_fragments: *std.StringHashMap(void)) !void {
        const root_type = switch (op.op_type) {
            .query => self.schema_def.query_type,
            .mutation => self.schema_def.mutation_type orelse {
                try self.result.addError("Schema does not support mutations", op.line, op.col);
                return;
            },
            .subscription => self.schema_def.subscription_type orelse {
                try self.result.addError("Schema does not support subscriptions", op.line, op.col);
                return;
            },
        };

        // Collect variables
        for (op.variable_definitions.items) |*vd| {
            if (self.variables.contains(vd.name)) {
                try self.result.addError("Variable name must be unique within operation", null, null);
            } else {
                const var_type = try self.allocator.create(ast.Type);
                var_type.* = try self.convertTypeRef(&vd.var_type);
                try self.variables.put(vd.name, var_type);
            }

            // §5.8.2 VariablesAreInputTypes: the variable's named type must be
            // an input type (scalar, enum, or input object).
            try self.validateVariableType(vd);

            // Variable default values must be constant (no variable references).
            if (vd.default_value) |*dv| {
                if (try self.astValueContainsVariable(dv)) {
                    try self.result.addError("Variable default value must be constant", op.line, null);
                }
            }
        }

        const op_location: schema.DirectiveLocation = switch (op.op_type) {
            .query => .query,
            .mutation => .mutation,
            .subscription => .subscription,
        };
        try self.validateDirectives(op.directives, op_location);

        try self.validateSelectionSet(&op.selection_set, root_type, validated_fragments);

        // Clean up variables for this operation
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.variables.clearRetainingCapacity();
    }

    /// §5.8.2 VariablesAreInputTypes: unwrap the variable type and verify the
    /// named type is an input type.
    fn validateVariableType(self: *Validator, vd: *ast.VariableDefinition) ValidateError!void {
        var t = &vd.var_type;
        while (true) {
            switch (t.*) {
                .named => |n| {
                    const schema_type = self.schema_def.getType(n.name);
                    if (schema_type == null) {
                        try self.result.addError("Variable type does not exist in schema", null, null);
                    } else if (!schema_type.?.isInputType()) {
                        try self.result.addError("Variable type must be an input type", null, null);
                    }
                    return;
                },
                .list => |inner| t = inner,
                .non_null => |inner| t = inner,
            }
        }
    }

    /// Returns true if the AST value contains a variable reference anywhere.
    fn astValueContainsVariable(self: *Validator, value: *ast.AstValue) ValidateError!bool {
        switch (value.*) {
            .variable => return true,
            .list_value => |*list| {
                for (list.items) |*item| {
                    if (try self.astValueContainsVariable(item)) return true;
                }
                return false;
            },
            .object_value => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    if (try self.astValueContainsVariable(entry.value_ptr)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// §5.3.2 OverlappingFieldsCanBeMerged: collect fields by response key and
    /// verify that fields with the same key target the same schema field with
    /// identical arguments.
    fn validateFieldMerging(self: *Validator, ss: *ast.SelectionSet) ValidateError!void {
        // Map response key -> first field (name + argument signature).
        var seen = std.StringHashMap(FieldSig).init(self.allocator);
        defer {
            var iter = seen.keyIterator();
            while (iter.next()) |k| self.allocator.free(k.*);
            seen.deinit();
        }

        for (ss.selections.items) |*sel| {
            switch (sel.*) {
                .field => |*field| {
                    const key = field.alias orelse field.name;
                    const sig = FieldSig{
                        .field_name = field.name,
                        .args = field.arguments.items,
                    };
                    if (seen.get(key)) |existing| {
                        if (!std.mem.eql(u8, existing.field_name, sig.field_name)) {
                            try self.result.addError("Fields with the same response key must target the same field", field.line, field.col);
                        } else if (!self.argsEqual(existing.args, sig.args)) {
                            try self.result.addError("Fields with the same response key must have identical arguments", field.line, field.col);
                        }
                    } else {
                        try seen.put(try self.allocator.dupe(u8, key), sig);
                    }
                },
                else => {},
            }
        }
    }

    const FieldSig = struct {
        field_name: []const u8,
        args: []const ast.Argument,
    };

    fn argsEqual(self: *Validator, a: []const ast.Argument, b: []const ast.Argument) bool {
        if (a.len != b.len) return false;
        // Compare as a multiset by name+value.
        var matched = std.DynamicBitSetUnmanaged.initEmpty(self.allocator, b.len) catch return false;
        defer matched.deinit(self.allocator);
        for (a) |arg_a| {
            var found = false;
            for (b, 0..) |arg_b, j| {
                if (matched.isSet(j)) continue;
                if (std.mem.eql(u8, arg_a.name, arg_b.name) and self.astValueEqual(&arg_a.value, &arg_b.value)) {
                    matched.set(j);
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn astValueEqual(self: *Validator, a: *const ast.AstValue, b: *const ast.AstValue) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .variable => |v| std.mem.eql(u8, v, b.variable),
            .int_value => |v| std.mem.eql(u8, v, b.int_value),
            .float_value => |v| std.mem.eql(u8, v, b.float_value),
            .string_value => |v| std.mem.eql(u8, v, b.string_value),
            .boolean_value => |v| v == b.boolean_value,
            .null_value => true,
            .enum_value => |v| std.mem.eql(u8, v, b.enum_value),
            .list_value => |v| {
                if (v.items.len != b.list_value.items.len) return false;
                for (v.items, b.list_value.items) |x, y| {
                    if (!self.astValueEqual(&x, &y)) return false;
                }
                return true;
            },
            .object_value => |v| {
                if (v.count() != b.object_value.count()) return false;
                var iter = v.iterator();
                while (iter.next()) |entry| {
                    const other = b.object_value.get(entry.key_ptr.*) orelse return false;
                    if (!self.astValueEqual(entry.value_ptr, &other)) return false;
                }
                return true;
            },
        };
    }

    fn validateFragment(self: *Validator, frag: *ast.FragmentDefinition, validated_fragments: *std.StringHashMap(void)) !void {        const type_name = frag.type_condition.name;
        const frag_type = self.schema_def.getType(type_name);
        if (frag_type == null) {
            try self.result.addError("Fragment type condition does not exist in schema", frag.line, frag.col);
            return;
        }
        if (!frag_type.?.isComposite()) {
            try self.result.addError("Fragment type condition must be a composite type (object, interface, or union)", frag.line, frag.col);
            return;
        }
        try self.validateDirectives(frag.directives, .fragment_definition);
        try self.validateSelectionSet(&frag.selection_set, frag_type.?, validated_fragments);
    }

    const ValidateError = std.mem.Allocator.Error || error{UnexpectedToken};

    fn validateSelectionSet(self: *Validator, ss: *ast.SelectionSet, parent_type: *schema.Type, validated_fragments: *std.StringHashMap(void)) ValidateError!void {
        if (!parent_type.isComposite()) {
            try self.result.addError("Selection set only allowed on composite types", null, null);
            return;
        }

        if (ss.selections.items.len == 0) {
            try self.result.addError("Selection set must not be empty on composite type", null, null);
            return;
        }

        // §5.3.2 OverlappingFieldsCanBeMerged: fields sharing a response key
        // must have the same target field and identical arguments.
        try self.validateFieldMerging(ss);

        for (ss.selections.items) |*sel| {
            switch (sel.*) {
                .field => |*field| try self.validateField(field, parent_type, validated_fragments),
                .fragment_spread => |*fs| try self.validateFragmentSpread(fs, parent_type, validated_fragments),
                .inline_fragment => |*ifrag| try self.validateInlineFragment(ifrag, parent_type, validated_fragments),
            }
        }
    }

    fn validateField(self: *Validator, field: *ast.Field, parent_type: *schema.Type, validated_fragments: *std.StringHashMap(void)) ValidateError!void {
        // GraphQL introspection meta-fields are always valid
        if (std.mem.eql(u8, field.name, "__typename")) {
            if (field.selection_set != null) {
                try self.result.addError("__typename must not have a sub-selection", field.line, field.col);
            }
            return;
        }
        if (std.mem.eql(u8, field.name, "__schema")) {
            try self.validateDirectives(field.directives, .field);
            try self.validateIntrospectionSelectionSet(field, "__Schema");
            return;
        }
        if (std.mem.eql(u8, field.name, "__type")) {
            try self.validateDirectives(field.directives, .field);
            for (field.arguments.items) |arg| {
                if (std.mem.eql(u8, arg.name, "name")) {
                    if (arg.value != .string_value) {
                        try self.result.addError("__type name argument must be a string", field.line, field.col);
                    }
                } else {
                    try self.result.addError("Unknown argument on __type", field.line, field.col);
                }
            }
            try self.validateIntrospectionSelectionSet(field, "__Type");
            return;
        }

        const field_def = parent_type.getField(field.name);
        if (field_def == null) {
            try self.result.addError("Field does not exist on type", field.line, field.col);
            return;
        }

        try self.validateDirectives(field.directives, .field);

        // Check argument uniqueness
        for (field.arguments.items, 0..) |*arg, i| {
            for (field.arguments.items[i + 1 ..]) |*other| {
                if (std.mem.eql(u8, arg.name, other.name)) {
                    try self.result.addError("Duplicate argument name", field.line, field.col);
                    break;
                }
            }
        }

        // Validate arguments
        for (field.arguments.items) |arg| {
            const arg_def = field_def.?.arguments.get(arg.name);
            if (arg_def == null) {
                try self.result.addError("Unknown argument", null, null);
                continue;
            }
            try self.validateArgumentValue(arg.value, arg_def.?.value_type);
        }

        // Check that all required (NonNull) arguments are provided
        var arg_iter = field_def.?.arguments.iterator();
        while (arg_iter.next()) |entry| {
            if (entry.value_ptr.value_type.isNonNull()) {
                var found = false;
                for (field.arguments.items) |a| {
                    if (std.mem.eql(u8, a.name, entry.key_ptr.*)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.result.addError("Missing required argument", field.line, field.col);
                }
            }
        }

        // Validate sub-selection
        if (field.selection_set) |*ss| {
            const field_type_name = field_def.?.field_type.innerTypeName();
            const field_type = self.schema_def.getType(field_type_name);
            if (field_type) |ft| {
                if (!ft.isComposite()) {
                    try self.result.addError("Leaf field must not have a sub-selection", field.line, field.col);
                    return;
                }
                try self.validateSelectionSet(ss, ft, validated_fragments);
            }
        }
    }

    fn validateFragmentSpread(self: *Validator, fs: *ast.FragmentSpread, parent_type: *schema.Type, validated_fragments: *std.StringHashMap(void)) ValidateError!void {
        try self.validateDirectives(fs.directives, .fragment_spread);
        const frag = self.fragments.get(fs.name);
        if (frag == null) {
            try self.result.addError("Fragment not defined", fs.line, fs.col);
            return;
        }
        // Check fragment type condition is applicable to parent type
        const frag_type = self.schema_def.getType(frag.?.type_condition.name);
        if (frag_type) |ft| {
            if (!self.isTypeSubType(parent_type, ft)) {
                try self.result.addError("Fragment type condition not applicable here", fs.line, fs.col);
            }
        }
        // Validate fragment internals with operation's variables in scope
        if (!validated_fragments.contains(fs.name)) {
            const key = try self.allocator.dupe(u8, fs.name);
            try validated_fragments.put(key, {});
            try self.validateFragment(frag.?, validated_fragments);
        }
    }

    fn validateInlineFragment(self: *Validator, ifrag: *ast.InlineFragment, parent_type: *schema.Type, validated_fragments: *std.StringHashMap(void)) ValidateError!void {
        try self.validateDirectives(ifrag.directives, .inline_fragment);
        if (ifrag.type_condition) |tc| {
            const tc_type = self.schema_def.getType(tc.name);
            if (tc_type == null) {
                try self.result.addError("Inline fragment type condition does not exist", ifrag.line, ifrag.col);
                return;
            }
            if (!self.isTypeSubType(parent_type, tc_type.?)) {
                try self.result.addError("Inline fragment type condition not applicable here", ifrag.line, ifrag.col);
            }
            try self.validateSelectionSet(&ifrag.selection_set, tc_type.?, validated_fragments);
        } else {
            try self.validateSelectionSet(&ifrag.selection_set, parent_type, validated_fragments);
        }
    }

    /// Validate the sub-selection of an introspection meta-field (__schema / __type).
    /// The introspection types are not part of the user schema, so this uses a
    /// static description of the GraphQL introspection type system instead of
    /// looking them up in `schema_def` (which previously made the check a no-op).
    fn validateIntrospectionSelectionSet(self: *Validator, field: *ast.Field, intro_type: []const u8) ValidateError!void {
        const ss = field.selection_set orelse {
            try self.result.addError("Introspection field must have a sub-selection", field.line, field.col);
            return;
        };

        for (ss.selections.items) |*sel| {
            switch (sel.*) {
                .field => |*sub| try self.validateIntrospectionField(sub, intro_type),
                .fragment_spread, .inline_fragment => {
                    const lc = sub_line_col(sel);
                    try self.result.addError("Fragments are not supported inside introspection selections", lc.line, lc.col);
                },
            }
        }
    }

    fn validateIntrospectionField(self: *Validator, sub: *ast.Field, intro_type: []const u8) ValidateError!void {
        if (std.mem.eql(u8, sub.name, "__typename")) return;

        const field_def = introspectionFieldDef(intro_type, sub.name) orelse {
            try self.result.addError("Field does not exist on introspection type", sub.line, sub.col);
            return;
        };

        // Validate arguments
        for (sub.arguments.items) |arg| {
            if (field_def.args.len == 0) {
                try self.result.addError("Field does not accept arguments", sub.line, sub.col);
            } else {
                var found = false;
                for (field_def.args) |arg_name| {
                    if (std.mem.eql(u8, arg.name, arg_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.result.addError("Unknown argument on introspection field", sub.line, sub.col);
                }
            }
        }

        // A field whose type is a composite introspection type must have a sub-selection.
        if (field_def.nested_type) |nested| {
            if (sub.selection_set == null) {
                try self.result.addError("Field requires a sub-selection", sub.line, sub.col);
                return;
            }
            try self.validateIntrospectionSelectionSet(sub, nested);
        } else {
            if (sub.selection_set != null) {
                try self.result.addError("Field must not have a sub-selection", sub.line, sub.col);
            }
        }
    }

    fn sub_line_col(sel: *const ast.Selection) struct { line: ?usize, col: ?usize } {
        return switch (sel.*) {
            .field => |f| .{ .line = f.line, .col = f.col },
            .fragment_spread => |f| .{ .line = f.line, .col = f.col },
            .inline_fragment => |f| .{ .line = f.line, .col = f.col },
        };
    }

    fn validateDirectives(self: *Validator, directives: std.array_list.Managed(ast.Directive), location: schema.DirectiveLocation) ValidateError!void {        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (directives.items) |dir| {
            // Check if directive is defined in schema
            const def = self.schema_def.getDirective(dir.name);
            if (def == null) {
                try self.result.addError("Unknown directive", dir.line, dir.col);
                continue;
            }

            // Check location validity
            var location_valid = false;
            for (def.?.locations.items) |loc| {
                if (loc == location) {
                    location_valid = true;
                    break;
                }
            }
            if (!location_valid) {
                try self.result.addError("Directive not valid in this location", dir.line, dir.col);
            }

            // Check repeatability
            if (!def.?.is_repeatable) {
                if (seen.contains(dir.name)) {
                    try self.result.addError("Directive is not repeatable", dir.line, dir.col);
                }
                try seen.put(dir.name, {});
            }

            // Validate arguments against directive definition
            for (dir.arguments.items) |arg| {
                const arg_def = def.?.arguments.get(arg.name);
                if (arg_def == null) {
                    try self.result.addError("Unknown argument on directive", dir.line, dir.col);
                    continue;
                }
            }

            // Check required arguments
            var aiter = def.?.arguments.iterator();
            while (aiter.next()) |entry| {
                const arg_name = entry.key_ptr.*;
                const arg_def = entry.value_ptr.*;
                if (arg_def.value_type.isNonNull()) {
                    var found = false;
                    for (dir.arguments.items) |a| {
                        if (std.mem.eql(u8, a.name, arg_name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try self.result.addError("Missing required argument on directive", dir.line, dir.col);
                    }
                }
            }

            // Specific checks for built-in directives
            if (std.mem.eql(u8, dir.name, "skip") or std.mem.eql(u8, dir.name, "include")) {
                for (dir.arguments.items) |arg| {
                    if (std.mem.eql(u8, arg.name, "if")) {
                        switch (arg.value) {
                            .variable => |var_name| {
                                if (!self.variables.contains(var_name)) {
                                    try self.result.addError("Variable not defined in directive argument", null, null);
                                }
                            },
                            .boolean_value => {},
                            else => try self.result.addError("Directive 'if' argument must be a boolean or variable", null, null),
                        }
                        break;
                    }
                }
            }
        }
    }

    fn isTypeSubType(self: *Validator, parent: *schema.Type, maybe_subtype: *schema.Type) bool {
        _ = self;
        if (parent.name.len == maybe_subtype.name.len and
            std.mem.eql(u8, parent.name, maybe_subtype.name)) return true;
        if (parent.isObject() and maybe_subtype.isInterface()) {
            for (parent.kind.object.interfaces.items) |iface| {
                if (std.mem.eql(u8, iface, maybe_subtype.name)) return true;
            }
        }
        if (parent.isUnion()) {
            for (parent.kind.union_type.possible_types.items) |pt| {
                if (std.mem.eql(u8, pt, maybe_subtype.name)) return true;
            }
        }
        return false;
    }

    fn isVariableTypeCompatible(self: *Validator, var_type: ast.Type, expected: schema.TypeRef) bool {
        switch (var_type) {
            .named => |n| {
                if (expected.kind != .named) return false;
                return std.mem.eql(u8, n.name, expected.kind.named);
            },
            .non_null => |ptr| {
                if (expected.kind == .non_null) {
                    return self.isVariableTypeCompatible(ptr.*, expected.kind.non_null.*);
                }
                // A non-null variable can be used where a nullable type is expected
                return self.isVariableTypeCompatible(ptr.*, expected);
            },
            .list => |ptr| {
                if (expected.kind == .non_null) {
                    return self.isVariableTypeCompatible(var_type, expected.kind.non_null.*);
                }
                if (expected.kind != .list) return false;
                return self.isVariableTypeCompatible(ptr.*, expected.kind.list.*);
            },
        }
    }

    fn validateArgumentValue(self: *Validator, value: ast.AstValue, expected_type: schema.TypeRef) ValidateError!void {
        switch (value) {
            .variable => |var_name| {
                const var_type_ptr = self.variables.get(var_name);
                if (var_type_ptr == null) {
                    try self.result.addError("Variable not defined", null, null);
                    return;
                }
                if (!self.isVariableTypeCompatible(var_type_ptr.?.*, expected_type)) {
                    try self.result.addError("Variable type does not match expected argument type", null, null);
                }
            },
            .null_value => {
                if (expected_type.isNonNull()) {
                    try self.result.addError("Null value for non-null argument", null, null);
                }
            },
            .int_value => {
                const inner = expected_type.innerTypeName();
                if (!std.mem.eql(u8, inner, "Int") and
                    !std.mem.eql(u8, inner, "Float") and
                    !std.mem.eql(u8, inner, "ID"))
                {
                    try self.result.addError("Int value for non-numeric argument", null, null);
                }
            },
            .float_value => {
                const inner = expected_type.innerTypeName();
                if (!std.mem.eql(u8, inner, "Float")) {
                    try self.result.addError("Float value for non-float argument", null, null);
                }
            },
            .string_value => {
                const inner = expected_type.innerTypeName();
                if (!std.mem.eql(u8, inner, "String") and
                    !std.mem.eql(u8, inner, "ID"))
                {
                    try self.result.addError("String value for non-string argument", null, null);
                }
            },
            .boolean_value => {
                const inner = expected_type.innerTypeName();
                if (!std.mem.eql(u8, inner, "Boolean")) {
                    try self.result.addError("Boolean value for non-boolean argument", null, null);
                }
            },
            .enum_value => |name| {
                const inner = expected_type.innerTypeName();
                const enum_type = self.schema_def.getType(inner);
                if (enum_type == null or !enum_type.?.isEnum()) {
                    try self.result.addError("Enum value for non-enum argument", null, null);
                    return;
                }
                if (enum_type.?.kind.enum_type.values.get(name) == null) {
                    try self.result.addError("Enum value not found", null, null);
                }
            },
            .list_value => |list| {
                const unwrapped = if (expected_type.kind == .non_null) expected_type.kind.non_null.* else expected_type;
                if (unwrapped.kind != .list) {
                    try self.result.addError("List value for non-list argument", null, null);
                    return;
                }
                const inner = unwrapped.kind.list.*;
                for (list.items) |item| {
                    try self.validateArgumentValue(item, inner);
                }
            },
            .object_value => |obj| {
                const inner = expected_type.innerTypeName();
                const input_type = self.schema_def.getType(inner);
                if (input_type == null or !input_type.?.isInputObject()) {
                    try self.result.addError("Object value for non-input-object argument", null, null);
                    return;
                }
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const field_name = entry.key_ptr.*;
                    const field_value = entry.value_ptr.*;
                    const input_field = input_type.?.kind.input_object.fields.get(field_name);
                    if (input_field == null) {
                        try self.result.addError("Unknown input object field", null, null);
                        continue;
                    }
                    try self.validateArgumentValue(field_value, input_field.?.value_type);
                }
                // Check that all required (NonNull) input fields are provided
                var field_iter = input_type.?.kind.input_object.fields.iterator();
                while (field_iter.next()) |entry| {
                    if (entry.value_ptr.value_type.isNonNull()) {
                        if (!obj.contains(entry.key_ptr.*)) {
                            try self.result.addError("Missing required input object field", null, null);
                        }
                    }
                }
            },
        }
    }

    fn convertTypeRef(self: *Validator, t: *ast.Type) std.mem.Allocator.Error!ast.Type {
        _ = self;
        // For validation purposes, we keep ast.Type.
        // This is a shallow copy since ast.Type contains pointers.
        return t.*;
    }
};

test "validator basic" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const user_field = schema.Field.init(allocator, "user", schema.TypeRef.named("User"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "user"), user_field);

    var user_type = try allocator.create(schema.Type);
    user_type.* = .{
        .name = "User",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const name_field = schema.Field.init(allocator, "name", schema.TypeRef.named("String"));
    try user_type.kind.object.fields.put(try allocator.dupe(u8, "name"), name_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("User", user_type);

    const source = "query { user { name } }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(result.isValid());
}

test "validator invalid field" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { nonexistent }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}

test "validator argument type mismatch" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    const arg = schema.InputValue{ .name = "greeting", .value_type = schema.TypeRef.named("String") };
    try hello_field.arguments.put(try allocator.dupe(u8, "greeting"), arg);
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    // Pass int where string expected
    const source = "query { hello(greeting: 123) }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}

test "validator enum argument" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var status_field = schema.Field.init(allocator, "status", schema.TypeRef.named("Status"));
    const arg = schema.InputValue{ .name = "filter", .value_type = schema.TypeRef.named("Status") };
    try status_field.arguments.put(try allocator.dupe(u8, "filter"), arg);
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "status"), status_field);

    var status_enum = try allocator.create(schema.Type);
    status_enum.* = .{
        .name = "Status",
        .kind = .{ .enum_type = schema.EnumType.init(allocator) },
    };
    try status_enum.kind.enum_type.values.put(try allocator.dupe(u8, "ACTIVE"), .{ .name = "ACTIVE" });
    try status_enum.kind.enum_type.values.put(try allocator.dupe(u8, "INACTIVE"), .{ .name = "INACTIVE" });

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("Status", status_enum);

    // Valid enum value
    const source = "query { status(filter: ACTIVE) }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(result.isValid());
}

test "validator invalid enum argument" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var status_field = schema.Field.init(allocator, "status", schema.TypeRef.named("Status"));
    const arg = schema.InputValue{ .name = "filter", .value_type = schema.TypeRef.named("Status") };
    try status_field.arguments.put(try allocator.dupe(u8, "filter"), arg);
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "status"), status_field);

    var status_enum = try allocator.create(schema.Type);
    status_enum.* = .{
        .name = "Status",
        .kind = .{ .enum_type = schema.EnumType.init(allocator) },
    };
    try status_enum.kind.enum_type.values.put(try allocator.dupe(u8, "ACTIVE"), .{ .name = "ACTIVE" });

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("Status", status_enum);

    // Invalid enum value
    const source = "query { status(filter: UNKNOWN) }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}

test "validator fragment cycle detection" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    // Direct cycle: A -> A
    const source1 = "query { ...A } fragment A on Query { ...A hello }";
    var parser1 = try @import("parser.zig").Parser.init(allocator, source1);
    defer parser1.deinit();
    var doc1 = try parser1.parseDocument();
    defer doc1.deinit();

    var validator1 = Validator.init(allocator, &schema_def);
    defer validator1.deinit();
    const result1 = try validator1.validate(&doc1);
    try std.testing.expect(!result1.isValid());

    // Indirect cycle: A -> B -> A
    const source2 = "query { ...A } fragment A on Query { ...B } fragment B on Query { ...A }";
    var parser2 = try @import("parser.zig").Parser.init(allocator, source2);
    defer parser2.deinit();
    var doc2 = try parser2.parseDocument();
    defer doc2.deinit();

    var validator2 = Validator.init(allocator, &schema_def);
    defer validator2.deinit();
    const result2 = try validator2.validate(&doc2);
    try std.testing.expect(!result2.isValid());

    // No cycle: A -> B (leaf)
    const source3 = "query { ...A } fragment A on Query { ...B } fragment B on Query { hello }";
    var parser3 = try @import("parser.zig").Parser.init(allocator, source3);
    defer parser3.deinit();
    var doc3 = try parser3.parseDocument();
    defer doc3.deinit();

    var validator3 = Validator.init(allocator, &schema_def);
    defer validator3.deinit();
    const result3 = try validator3.validate(&doc3);
    try std.testing.expect(result3.isValid());
}


test "validator undefined variable" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    var hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    hello_field.arguments = std.StringHashMap(schema.InputValue).init(allocator);
    try hello_field.arguments.put(try allocator.dupe(u8, "name"), .{ .name = "name", .value_type = schema.TypeRef.named("String") });
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { hello(name: $undefinedVar) }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.errors.items.len > 0);
}

test "validator directive missing if argument" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { hello @skip }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.errors.items.len > 0);
}

test "validator directive invalid if type" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { hello @include(if: \"yes\") }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
    try std.testing.expect(result.errors.items.len > 0);
}

test "validator valid directive" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { hello @skip(if: true) @include(if: false) }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(result.isValid());
}

test "validator unknown directive" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { hello @unknown }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
    var found = false;
    for (result.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Unknown directive") != null) found = true;
    }
    try std.testing.expect(found);
}

test "validator directive wrong location" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    // @skip is only valid on FIELD, FRAGMENT_SPREAD, INLINE_FRAGMENT — not on query operation
    const source = "query @skip(if: true) { hello }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
    var found = false;
    for (result.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Directive not valid in this location") != null) found = true;
    }
    try std.testing.expect(found);
}

test "validator directive not repeatable" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    const source = "query { hello @skip(if: true) @skip(if: false) }";
    var parser = try @import("parser.zig").Parser.init(allocator, source);
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
    var found = false;
    for (result.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Directive is not repeatable") != null) found = true;
    }
    try std.testing.expect(found);
}

/// Static description of the GraphQL introspection type system, used to
/// validate `__schema` / `__type` sub-selections without registering the
/// introspection types into the user schema.
const IntrospectionFieldDef = struct {
    /// Names of accepted arguments (empty = no arguments).
    args: []const []const u8,
    /// If non-null, this field's type is a composite introspection type and
    /// the field requires a sub-selection validated against `nested_type`.
    nested_type: ?[]const u8 = null,
};

fn introspectionFieldDef(type_name: []const u8, field_name: []const u8) ?IntrospectionFieldDef {
    // __Schema
    if (std.mem.eql(u8, type_name, "__Schema")) {
        if (std.mem.eql(u8, field_name, "types")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "queryType")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "mutationType")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "subscriptionType")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "directives")) return .{ .args = &.{}, .nested_type = "__Directive" };
        if (std.mem.eql(u8, field_name, "description")) return .{ .args = &.{} };
        return null;
    }
    // __Type
    if (std.mem.eql(u8, type_name, "__Type")) {
        if (std.mem.eql(u8, field_name, "kind")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "name")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "description")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "fields")) return .{ .args = &.{"includeDeprecated"}, .nested_type = "__Field" };
        if (std.mem.eql(u8, field_name, "interfaces")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "possibleTypes")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "enumValues")) return .{ .args = &.{"includeDeprecated"}, .nested_type = "__EnumValue" };
        if (std.mem.eql(u8, field_name, "inputFields")) return .{ .args = &.{"includeDeprecated"}, .nested_type = "__InputValue" };
        if (std.mem.eql(u8, field_name, "ofType")) return .{ .args = &.{}, .nested_type = "__Type" };
        return null;
    }
    // __Field
    if (std.mem.eql(u8, type_name, "__Field")) {
        if (std.mem.eql(u8, field_name, "name")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "description")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "args")) return .{ .args = &.{"includeDeprecated"}, .nested_type = "__InputValue" };
        if (std.mem.eql(u8, field_name, "type")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "isDeprecated")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "deprecationReason")) return .{ .args = &.{} };
        return null;
    }
    // __InputValue
    if (std.mem.eql(u8, type_name, "__InputValue")) {
        if (std.mem.eql(u8, field_name, "name")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "description")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "type")) return .{ .args = &.{}, .nested_type = "__Type" };
        if (std.mem.eql(u8, field_name, "defaultValue")) return .{ .args = &.{} };
        return null;
    }
    // __EnumValue
    if (std.mem.eql(u8, type_name, "__EnumValue")) {
        if (std.mem.eql(u8, field_name, "name")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "description")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "isDeprecated")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "deprecationReason")) return .{ .args = &.{} };
        return null;
    }
    // __Directive
    if (std.mem.eql(u8, type_name, "__Directive")) {
        if (std.mem.eql(u8, field_name, "name")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "description")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "locations")) return .{ .args = &.{} };
        if (std.mem.eql(u8, field_name, "args")) return .{ .args = &.{"includeDeprecated"}, .nested_type = "__InputValue" };
        if (std.mem.eql(u8, field_name, "isRepeatable")) return .{ .args = &.{} };
        return null;
    }
    return null;
}

test "validator validates introspection __schema sub-selection" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "ping"), schema.Field.init(allocator, "ping", schema.TypeRef.named("String")));

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    // Valid introspection query must pass validation.
    {
        var validator = Validator.init(allocator, &schema_def);
        defer validator.deinit();
        var parser = try @import("parser.zig").Parser.init(allocator, "{ __schema { queryType { name } types { name } } }");
        defer parser.deinit();
        var doc = try parser.parseDocument();
        defer doc.deinit();
        const result = try validator.validate(&doc);
        try std.testing.expect(result.isValid());
    }

    // Unknown field on __Schema must be rejected.
    {
        var validator = Validator.init(allocator, &schema_def);
        defer validator.deinit();
        var parser = try @import("parser.zig").Parser.init(allocator, "{ __schema { bogusField } }");
        defer parser.deinit();
        var doc = try parser.parseDocument();
        defer doc.deinit();
        const result = try validator.validate(&doc);
        try std.testing.expect(!result.isValid());
    }

    // Leaf field with a sub-selection must be rejected.
    {
        var validator = Validator.init(allocator, &schema_def);
        defer validator.deinit();
        var parser = try @import("parser.zig").Parser.init(allocator, "{ __schema { description { x } } }");
        defer parser.deinit();
        var doc = try parser.parseDocument();
        defer doc.deinit();
        const result = try validator.validate(&doc);
        try std.testing.expect(!result.isValid());
    }
}

test "validator validates introspection __type sub-selection" {
    const allocator = std.testing.allocator;

    const query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "ping"), schema.Field.init(allocator, "ping", schema.TypeRef.named("String")));

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    var parser = try @import("parser.zig").Parser.init(allocator, "{ __type(name: \"Query\") { name fields { name type { name } } } }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(result.isValid());
}

test "validator unique operation names" {
    const allocator = std.testing.allocator;
    const query_type = try allocator.create(schema.Type);
    query_type.* = .{ .name = "Query", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), schema.Field.init(allocator, "hello", schema.TypeRef.named("String")));
    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    var parser = try @import("parser.zig").Parser.init(allocator, "query A { hello } query A { hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}

test "validator lone anonymous operation" {
    const allocator = std.testing.allocator;
    const query_type = try allocator.create(schema.Type);
    query_type.* = .{ .name = "Query", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), schema.Field.init(allocator, "hello", schema.TypeRef.named("String")));
    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    var parser = try @import("parser.zig").Parser.init(allocator, "{ hello } query A { hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}

test "validator unused fragment" {
    const allocator = std.testing.allocator;
    const query_type = try allocator.create(schema.Type);
    query_type.* = .{ .name = "Query", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), schema.Field.init(allocator, "hello", schema.TypeRef.named("String")));
    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    var parser = try @import("parser.zig").Parser.init(allocator, "{ hello } fragment Unused on Query { hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}

test "validator variable must be input type" {
    const allocator = std.testing.allocator;
    const query_type = try allocator.create(schema.Type);
    query_type.* = .{ .name = "Query", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), schema.Field.init(allocator, "hello", schema.TypeRef.named("String")));
    // Register an object type (not an input type).
    const obj_type = try allocator.create(schema.Type);
    obj_type.* = .{ .name = "Obj", .kind = .{ .object = schema.ObjectType.init(allocator) } };
    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);
    try schema_def.registerType("Obj", obj_type);

    var validator = Validator.init(allocator, &schema_def);
    defer validator.deinit();
    var parser = try @import("parser.zig").Parser.init(allocator, "query Q($v: Obj) { hello }");
    defer parser.deinit();
    var doc = try parser.parseDocument();
    defer doc.deinit();
    const result = try validator.validate(&doc);
    try std.testing.expect(!result.isValid());
}
