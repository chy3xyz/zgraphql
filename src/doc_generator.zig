const std = @import("std");
const schema = @import("schema.zig");

/// Generates Markdown API documentation from a GraphQL schema.
/// Walks the schema directly to produce human-readable documentation.
pub const DocGenerator = struct {
    allocator: std.mem.Allocator,
    buf: std.array_list.Managed(u8),

    pub fn generate(allocator: std.mem.Allocator, schema_def: *schema.Schema) std.mem.Allocator.Error![]const u8 {
        var gen = DocGenerator{
            .allocator = allocator,
            .buf = std.array_list.Managed(u8).init(allocator),
        };
        errdefer gen.buf.deinit();

        try gen.write("# Schema Documentation\n\n");
        try gen.write("*Auto-generated from GraphQL schema.*\n\n");

        // Table of Contents
        try gen.write("## Table of Contents\n\n");
        try gen.write("- [Query](#query)\n");
        if (schema_def.mutation_type) |_| try gen.write("- [Mutation](#mutation)\n");
        if (schema_def.subscription_type) |_| try gen.write("- [Subscription](#subscription)\n");
        try gen.write("- [Types](#types)\n");
        try gen.write("\n---\n\n");

        // Query
        try gen.generateTypeSection(schema_def, schema_def.query_type, "Query");

        // Mutation
        if (schema_def.mutation_type) |mt| {
            try gen.write("\n---\n\n");
            try gen.generateTypeSection(schema_def, mt, "Mutation");
        }

        // Subscription
        if (schema_def.subscription_type) |st| {
            try gen.write("\n---\n\n");
            try gen.generateTypeSection(schema_def, st, "Subscription");
        }

        // All other types
        try gen.write("\n---\n\n");
        try gen.write("## Types\n\n");

        var iter = schema_def.types.iterator();
        while (iter.next()) |entry| {
            const typ = entry.value_ptr.*;
            if (typ == schema_def.query_type) continue;
            if (schema_def.mutation_type) |mt| if (typ == mt) continue;
            if (schema_def.subscription_type) |st| if (typ == st) continue;

            try gen.generateTypeDoc(schema_def, typ);
            try gen.write("\n");
        }

        return gen.buf.toOwnedSlice();
    }

    fn write(self: *DocGenerator, s: []const u8) std.mem.Allocator.Error!void {
        try self.buf.appendSlice(s);
    }

    fn writeFmt(self: *DocGenerator, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.buf.appendSlice(s);
    }

    fn writeIndent(self: *DocGenerator, count: usize) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.buf.appendSlice("  ");
        }
    }

    fn generateTypeSection(self: *DocGenerator, schema_def: *schema.Schema, typ: *schema.Type, heading: []const u8) std.mem.Allocator.Error!void {
        _ = schema_def;
        try self.writeFmt("## {s}\n\n", .{heading});

        if (typ.description) |desc| {
            try self.writeFmt("{s}\n\n", .{desc});
        }

        switch (typ.kind) {
            .object => |*obj| {
                var fiter = obj.fields.iterator();
                while (fiter.next()) |entry| {
                    const field = entry.value_ptr.*;
                    try self.generateFieldDoc(field, 0);
                }
            },
            else => {},
        }
    }

    fn generateTypeDoc(self: *DocGenerator, _: *schema.Schema, typ: *schema.Type) std.mem.Allocator.Error!void {
        try self.writeFmt("### {s}\n\n", .{typ.name});

        if (typ.description) |desc| {
            try self.writeFmt("{s}\n\n", .{desc});
        }

        switch (typ.kind) {
            .scalar => try self.write("**Kind:** `Scalar`\n\n"),
            .object => |*obj| {
                try self.write("**Kind:** `Object`\n\n");
                if (obj.interfaces.items.len > 0) {
                    try self.write("**Implements:** ");
                    for (obj.interfaces.items, 0..) |iname, i| {
                        if (i > 0) try self.write(", ");
                        try self.writeFmt("`{s}`", .{iname});
                    }
                    try self.write("\n\n");
                }
                try self.write("**Fields:**\n\n");
                var fiter = obj.fields.iterator();
                while (fiter.next()) |entry| {
                    const field = entry.value_ptr.*;
                    try self.generateFieldDoc(field, 2);
                }
            },
            .interface => |*iface| {
                try self.write("**Kind:** `Interface`\n\n");
                try self.write("**Fields:**\n\n");
                var fiter = iface.fields.iterator();
                while (fiter.next()) |entry| {
                    const field = entry.value_ptr.*;
                    try self.generateFieldDoc(field, 2);
                }
            },
            .union_type => |*u| {
                try self.write("**Kind:** `Union`\n\n");
                try self.write("**Possible Types:** ");
                for (u.possible_types.items, 0..) |pt, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeFmt("`{s}`", .{pt});
                }
                try self.write("\n\n");
            },
            .enum_type => |*e| {
                try self.write("**Kind:** `Enum`\n\n");
                try self.write("| Value | Description |\n");
                try self.write("|-------|-------------|\n");
                var eviter = e.values.iterator();
                while (eviter.next()) |entry| {
                    try self.writeFmt("| `{s}` | |\n", .{entry.value_ptr.*.name});
                }
                try self.write("\n");
            },
            .input_object => |*io| {
                try self.write("**Kind:** `Input Object`\n\n");
                try self.write("**Fields:**\n\n");
                var fiter = io.fields.iterator();
                while (fiter.next()) |entry| {
                    const iv = entry.value_ptr.*;
                    try self.write("- `");
                    try self.write(iv.name);
                    try self.write("`: ");
                    try self.writeTypeRef(&iv.value_type);
                    try self.write("\n");
                }
                try self.write("\n");
            },
        }
    }

    fn generateFieldDoc(self: *DocGenerator, field: schema.Field, indent: usize) std.mem.Allocator.Error!void {
        try self.writeIndent(indent);
        try self.write("- **");
        try self.write(field.name);
        try self.write("**");
        if (field.arguments.count() > 0) {
            try self.write("(");
            var aiter = field.arguments.iterator();
            var first = true;
            while (aiter.next()) |entry| {
                if (!first) try self.write(", ");
                first = false;
                const arg = entry.value_ptr.*;
                try self.write(arg.name);
                try self.write(": ");
                try self.writeTypeRef(&arg.value_type);
            }
            try self.write(")");
        }
        try self.write(": ");
        try self.writeTypeRef(&field.field_type);
        if (field.deprecation_reason) |dr| {
            try self.writeFmt(" *(deprecated: {s})*", .{dr});
        }
        if (field.required_role) |role| {
            try self.writeFmt(" *(auth: `{s}`)*", .{role});
        }
        try self.write("\n");
    }

    fn writeTypeRef(self: *DocGenerator, t: *const schema.TypeRef) std.mem.Allocator.Error!void {
        switch (t.kind) {
            .named => |name| try self.writeFmt("`{s}`", .{name}),
            .list => |inner| {
                try self.write("[");
                try self.writeTypeRef(inner);
                try self.write("]");
            },
            .non_null => |inner| {
                try self.writeTypeRef(inner);
                try self.write("!");
            },
        }
    }
};

test "doc generator basic" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var user_field = schema.Field.init(allocator, "user", schema.TypeRef.named("User"));
    try user_field.arguments.put(try allocator.dupe(u8, "id"), schema.InputValue{
        .name = "id",
        .value_type = schema.TypeRef.named("ID"),
    });
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
    try schema_def.registerType("User", user_type);
    try schema_def.registerType("Query", query_type);

    const md = try DocGenerator.generate(allocator, &schema_def);
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "# Schema Documentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "## Query") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "User") != null);
}
