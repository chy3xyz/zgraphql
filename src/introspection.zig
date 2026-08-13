const std = @import("std");
const schema = @import("schema.zig");
const Value = @import("value.zig").Value;

/// Generates the GraphQL introspection query result for a schema.
pub const Introspection = struct {
    pub fn buildSchemaValue(allocator: std.mem.Allocator, schema_def: *schema.Schema) std.mem.Allocator.Error!Value {
        var result = Value.initObject(allocator);
        errdefer result.deinit(allocator);

        // description (schema-level)
        try result.data.object.put(try allocator.dupe(u8, "description"), try nullableString(allocator, schema_def.description));

        // types
        var types_list = Value.initList(allocator);
        errdefer types_list.deinit(allocator);
        var iter = schema_def.types.iterator();
        while (iter.next()) |entry| {
            try types_list.data.list.append(try buildTypeValue(allocator, schema_def, entry.value_ptr.*));
        }
        try result.data.object.put(try allocator.dupe(u8, "types"), types_list);

        // queryType
        try result.data.object.put(try allocator.dupe(u8, "queryType"), try buildTypeValue(allocator, schema_def, schema_def.query_type));

        // mutationType
        if (schema_def.mutation_type) |mt| {
            try result.data.object.put(try allocator.dupe(u8, "mutationType"), try buildTypeValue(allocator, schema_def, mt));
        } else {
            try result.data.object.put(try allocator.dupe(u8, "mutationType"), Value.fromNull(allocator));
        }

        // subscriptionType
        if (schema_def.subscription_type) |st| {
            try result.data.object.put(try allocator.dupe(u8, "subscriptionType"), try buildTypeValue(allocator, schema_def, st));
        } else {
            try result.data.object.put(try allocator.dupe(u8, "subscriptionType"), Value.fromNull(allocator));
        }

        // directives
        var directives_list = Value.initList(allocator);
        errdefer directives_list.deinit(allocator);
        var diter = schema_def.directives.iterator();
        while (diter.next()) |entry| {
            try directives_list.data.list.append(try buildDirectiveValue(allocator, schema_def, entry.value_ptr.*));
        }
        try result.data.object.put(try allocator.dupe(u8, "directives"), directives_list);

        return result;
    }

    pub fn buildTypeValue(allocator: std.mem.Allocator, schema_def: *schema.Schema, typ: *schema.Type) std.mem.Allocator.Error!Value {
        var obj = Value.initObject(allocator);
        errdefer obj.deinit(allocator);

        try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, typ.name)));
        try obj.data.object.put(try allocator.dupe(u8, "kind"), Value.fromString(allocator, try allocator.dupe(u8, typeKindString(typ))));
        try obj.data.object.put(try allocator.dupe(u8, "description"), try nullableString(allocator, typ.description));

        switch (typ.kind) {
            .object => |*obj_type| {
                var fields = Value.initList(allocator);
                errdefer fields.deinit(allocator);
                var fiter = obj_type.fields.iterator();
                while (fiter.next()) |entry| {
                    try fields.data.list.append(try buildFieldValue(allocator, schema_def, entry.value_ptr.*));
                }
                try obj.data.object.put(try allocator.dupe(u8, "fields"), fields);

                // interfaces
                var interfaces = Value.initList(allocator);
                errdefer interfaces.deinit(allocator);
                for (obj_type.interfaces.items) |iface_name| {
                    if (schema_def.getType(iface_name)) |iface_type| {
                        try interfaces.data.list.append(try buildTypeValue(allocator, schema_def, iface_type));
                    }
                }
                try obj.data.object.put(try allocator.dupe(u8, "interfaces"), interfaces);

                // possibleTypes and enumValues are null for objects
                try obj.data.object.put(try allocator.dupe(u8, "possibleTypes"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "enumValues"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "inputFields"), Value.fromNull(allocator));
            },
            .scalar => {
                try obj.data.object.put(try allocator.dupe(u8, "fields"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "interfaces"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "possibleTypes"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "enumValues"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "inputFields"), Value.fromNull(allocator));
            },
            .interface => |*iface_type| {
                var fields = Value.initList(allocator);
                errdefer fields.deinit(allocator);
                var fiter = iface_type.fields.iterator();
                while (fiter.next()) |entry| {
                    try fields.data.list.append(try buildFieldValue(allocator, schema_def, entry.value_ptr.*));
                }
                try obj.data.object.put(try allocator.dupe(u8, "fields"), fields);

                try obj.data.object.put(try allocator.dupe(u8, "interfaces"), Value.initList(allocator));

                // possibleTypes: objects that implement this interface
                var possible_types = Value.initList(allocator);
                errdefer possible_types.deinit(allocator);
                var titer = schema_def.types.iterator();
                while (titer.next()) |entry| {
                    const t = entry.value_ptr.*;
                    if (t.isObject()) {
                        for (t.kind.object.interfaces.items) |iname| {
                            if (std.mem.eql(u8, iname, typ.name)) {
                                try possible_types.data.list.append(try buildTypeValue(allocator, schema_def, t));
                                break;
                            }
                        }
                    }
                }
                try obj.data.object.put(try allocator.dupe(u8, "possibleTypes"), possible_types);
                try obj.data.object.put(try allocator.dupe(u8, "enumValues"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "inputFields"), Value.fromNull(allocator));
            },
            .union_type => |*u| {
                try obj.data.object.put(try allocator.dupe(u8, "fields"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "interfaces"), Value.initList(allocator));

                var possible_types = Value.initList(allocator);
                errdefer possible_types.deinit(allocator);
                for (u.possible_types.items) |pt_name| {
                    if (schema_def.getType(pt_name)) |pt_type| {
                        try possible_types.data.list.append(try buildTypeValue(allocator, schema_def, pt_type));
                    }
                }
                try obj.data.object.put(try allocator.dupe(u8, "possibleTypes"), possible_types);
                try obj.data.object.put(try allocator.dupe(u8, "enumValues"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "inputFields"), Value.fromNull(allocator));
            },
            .enum_type => |*e| {
                try obj.data.object.put(try allocator.dupe(u8, "fields"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "interfaces"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "possibleTypes"), Value.fromNull(allocator));

                var enum_values = Value.initList(allocator);
                errdefer enum_values.deinit(allocator);
                var eviter = e.values.iterator();
                while (eviter.next()) |entry| {
                    var ev_obj = Value.initObject(allocator);
                    try ev_obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, entry.value_ptr.*.name)));
                    try ev_obj.data.object.put(try allocator.dupe(u8, "description"), try nullableString(allocator, entry.value_ptr.*.description));
                    try ev_obj.data.object.put(try allocator.dupe(u8, "isDeprecated"), Value.fromBool(allocator, false));
                    try ev_obj.data.object.put(try allocator.dupe(u8, "deprecationReason"), Value.fromNull(allocator));
                    try enum_values.data.list.append(ev_obj);
                }
                try obj.data.object.put(try allocator.dupe(u8, "enumValues"), enum_values);
                try obj.data.object.put(try allocator.dupe(u8, "inputFields"), Value.fromNull(allocator));
            },
            .input_object => |*io_type| {
                try obj.data.object.put(try allocator.dupe(u8, "fields"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "interfaces"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "possibleTypes"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "enumValues"), Value.fromNull(allocator));

                var input_fields = Value.initList(allocator);
                errdefer input_fields.deinit(allocator);
                var ifiter = io_type.fields.iterator();
                while (ifiter.next()) |entry| {
                    try input_fields.data.list.append(try buildInputValueValue(allocator, schema_def, entry.value_ptr.*));
                }
                try obj.data.object.put(try allocator.dupe(u8, "inputFields"), input_fields);
            },
        }

        return obj;
    }

    fn buildFieldValue(allocator: std.mem.Allocator, schema_def: *schema.Schema, field: schema.Field) std.mem.Allocator.Error!Value {
        var obj = Value.initObject(allocator);
        errdefer obj.deinit(allocator);

        try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, field.name)));
        try obj.data.object.put(try allocator.dupe(u8, "description"), try nullableString(allocator, field.description));
        try obj.data.object.put(try allocator.dupe(u8, "type"), try buildTypeRefValue(allocator, schema_def, @constCast(&field.field_type)));

        var args = Value.initList(allocator);
        errdefer args.deinit(allocator);
        var aiter = field.arguments.iterator();
        while (aiter.next()) |entry| {
            try args.data.list.append(try buildInputValueValue(allocator, schema_def, entry.value_ptr.*));
        }
        try obj.data.object.put(try allocator.dupe(u8, "args"), args);

        try obj.data.object.put(try allocator.dupe(u8, "isDeprecated"), Value.fromBool(allocator, field.deprecation_reason != null));
        try obj.data.object.put(try allocator.dupe(u8, "deprecationReason"), if (field.deprecation_reason) |dr|
            Value.fromString(allocator, try allocator.dupe(u8, dr))
        else
            Value.fromNull(allocator));

        return obj;
    }

    fn buildTypeRefValue(allocator: std.mem.Allocator, schema_def: *schema.Schema, t: *schema.TypeRef) std.mem.Allocator.Error!Value {
        var obj = Value.initObject(allocator);
        errdefer obj.deinit(allocator);

        switch (t.kind) {
            .named => |name| {
                // Look up the named type in schema to determine its kind
                const named_type = schema_def.getType(name);
                const kind_str = if (named_type) |nt| typeKindString(nt) else "SCALAR";
                try obj.data.object.put(try allocator.dupe(u8, "kind"), Value.fromString(allocator, try allocator.dupe(u8, kind_str)));
                try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, name)));
                try obj.data.object.put(try allocator.dupe(u8, "ofType"), Value.fromNull(allocator));
            },
            .list => |inner| {
                try obj.data.object.put(try allocator.dupe(u8, "kind"), Value.fromString(allocator, try allocator.dupe(u8, "LIST")));
                try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "ofType"), try buildTypeRefValue(allocator, schema_def, inner));
            },
            .non_null => |inner| {
                try obj.data.object.put(try allocator.dupe(u8, "kind"), Value.fromString(allocator, try allocator.dupe(u8, "NON_NULL")));
                try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromNull(allocator));
                try obj.data.object.put(try allocator.dupe(u8, "ofType"), try buildTypeRefValue(allocator, schema_def, inner));
            },
        }
        return obj;
    }

    fn buildInputValueValue(allocator: std.mem.Allocator, schema_def: *schema.Schema, iv: schema.InputValue) std.mem.Allocator.Error!Value {
        var obj = Value.initObject(allocator);
        errdefer obj.deinit(allocator);

        try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, iv.name)));
        try obj.data.object.put(try allocator.dupe(u8, "description"), try nullableString(allocator, iv.description));
        try obj.data.object.put(try allocator.dupe(u8, "type"), try buildTypeRefValue(allocator, schema_def, @constCast(&iv.value_type)));
        if (iv.default_value) |dv| {
            const dv_json = dv.toJson(allocator) catch return error.OutOfMemory;
            try obj.data.object.put(try allocator.dupe(u8, "defaultValue"), Value.fromString(allocator, dv_json));
        } else {
            try obj.data.object.put(try allocator.dupe(u8, "defaultValue"), Value.fromNull(allocator));
        }

        return obj;
    }

    fn buildDirectiveValue(allocator: std.mem.Allocator, schema_def: *schema.Schema, dd: schema.DirectiveDefinition) std.mem.Allocator.Error!Value {
        var obj = Value.initObject(allocator);
        errdefer obj.deinit(allocator);

        try obj.data.object.put(try allocator.dupe(u8, "name"), Value.fromString(allocator, try allocator.dupe(u8, dd.name)));
        try obj.data.object.put(try allocator.dupe(u8, "description"), try nullableString(allocator, dd.description));

        var locations = Value.initList(allocator);
        errdefer locations.deinit(allocator);
        for (dd.locations.items) |loc| {
            try locations.data.list.append(Value.fromString(allocator, try allocator.dupe(u8, directiveLocationString(loc))));
        }
        try obj.data.object.put(try allocator.dupe(u8, "locations"), locations);

        var args = Value.initList(allocator);
        errdefer args.deinit(allocator);
        var aiter = dd.arguments.iterator();
        while (aiter.next()) |entry| {
            try args.data.list.append(try buildInputValueValue(allocator, schema_def, entry.value_ptr.*));
        }
        try obj.data.object.put(try allocator.dupe(u8, "args"), args);

        try obj.data.object.put(try allocator.dupe(u8, "isRepeatable"), Value.fromBool(allocator, dd.is_repeatable));

        return obj;
    }

    fn directiveLocationString(loc: schema.DirectiveLocation) []const u8 {
        return switch (loc) {
            .query => "QUERY",
            .mutation => "MUTATION",
            .subscription => "SUBSCRIPTION",
            .field => "FIELD",
            .fragment_definition => "FRAGMENT_DEFINITION",
            .fragment_spread => "FRAGMENT_SPREAD",
            .inline_fragment => "INLINE_FRAGMENT",
            .variable_definition => "VARIABLE_DEFINITION",
            .schema => "SCHEMA",
            .scalar => "SCALAR",
            .object => "OBJECT",
            .field_definition => "FIELD_DEFINITION",
            .argument_definition => "ARGUMENT_DEFINITION",
            .interface => "INTERFACE",
            .union_type => "UNION",
            .enum_type => "ENUM",
            .enum_value => "ENUM_VALUE",
            .input_object => "INPUT_OBJECT",
            .input_field_definition => "INPUT_FIELD_DEFINITION",
        };
    }

    /// Build a string Value from an optional description, or null.
    fn nullableString(allocator: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error!Value {
        if (s) |v| return Value.fromString(allocator, try allocator.dupe(u8, v));
        return Value.fromNull(allocator);
    }

    fn typeKindString(typ: *schema.Type) []const u8 {        return switch (typ.kind) {
            .scalar => "SCALAR",
            .object => "OBJECT",
            .interface => "INTERFACE",
            .union_type => "UNION",
            .enum_type => "ENUM",
            .input_object => "INPUT_OBJECT",
        };
    }
};

test "introspection basic" {
    const allocator = std.testing.allocator;

    var query_type = try allocator.create(schema.Type);
    query_type.* = .{
        .name = "Query",
        .kind = .{ .object = schema.ObjectType.init(allocator) },
    };
    const hello_field = schema.Field.init(allocator, "hello", schema.TypeRef.named("String"));
    try query_type.kind.object.fields.put(try allocator.dupe(u8, "hello"), hello_field);

    var schema_def = try schema.Schema.init(allocator, query_type);
    defer schema_def.deinit();
    try schema_def.registerType("Query", query_type);

    var result = try Introspection.buildSchemaValue(allocator, &schema_def);
    defer result.deinit(allocator);

    try std.testing.expect(result.data.object.contains("types"));
    try std.testing.expect(result.data.object.contains("queryType"));
}
