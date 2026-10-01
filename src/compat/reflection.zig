//! Stable field descriptors for toolkit reflection. Zig 0.17 exposes parallel
//! name/type/attribute arrays; collect them here so markup and wire schemas
//! continue to share one descriptor contract.
const std = @import("std");

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,
    alignment: usize,

    pub inline fn defaultValue(comptime field: StructField) ?field.type {
        const ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr orelse return null));
        return ptr.*;
    }
};

pub const EnumField = struct { name: [:0]const u8, value: comptime_int };
pub const UnionField = struct { name: [:0]const u8, type: type, alignment: usize };

fn Field(comptime Info: type) type {
    if (@hasField(Info, "field_values")) return EnumField;
    if (@hasField(@typeInfo(@FieldType(Info, "field_attrs")).pointer.child, "default_value_ptr")) return StructField;
    return UnionField;
}

pub fn fieldsOf(comptime info: anytype) [info.field_names.len]Field(@TypeOf(info)) {
    const F = Field(@TypeOf(info));
    var result: [info.field_names.len]F = undefined;
    for (info.field_names, 0..) |name, i| {
        result[i] = if (F == EnumField) .{
            .name = name,
            .value = info.field_values[i],
        } else if (F == StructField) .{
            .name = name,
            .type = info.field_types[i],
            .default_value_ptr = info.field_attrs[i].default_value_ptr,
            .is_comptime = info.field_attrs[i].@"comptime",
            .alignment = info.field_attrs[i].@"align" orelse @alignOf(info.field_types[i]),
        } else .{
            .name = name,
            .type = info.field_types[i],
            .alignment = info.field_attrs[i].@"align" orelse @alignOf(info.field_types[i]),
        };
    }
    return result;
}

pub fn fields(comptime T: type) switch (@typeInfo(T)) {
    .@"struct" => |info| [info.field_names.len]StructField,
    .@"union" => |info| [info.field_names.len]UnionField,
    .@"enum" => |info| [info.field_names.len]EnumField,
    else => @compileError("field reflection requires a container type"),
} {
    return switch (@typeInfo(T)) {
        inline .@"struct", .@"union", .@"enum" => |info| fieldsOf(info),
        else => unreachable,
    };
}

pub const Declaration = struct { name: [:0]const u8 };

pub fn declsOf(comptime info: anytype) [info.decl_names.len]Declaration {
    var result: [info.decl_names.len]Declaration = undefined;
    for (info.decl_names, 0..) |name, i| result[i] = .{ .name = name };
    return result;
}

test "descriptors retain field order, enum values, and defaults" {
    const S = struct { first: u32 = 7, second: bool };
    const sf = comptime fields(S);
    try std.testing.expectEqualStrings("first", sf[0].name);
    try std.testing.expectEqual(@as(?u32, 7), comptime sf[0].defaultValue());
    try std.testing.expectEqual(@as(?bool, null), comptime sf[1].defaultValue());
    const E = enum(u8) { first = 3, second = 9 };
    const ef = comptime fields(E);
    try std.testing.expectEqual(3, ef[0].value);
    try std.testing.expectEqual(9, ef[1].value);
}
