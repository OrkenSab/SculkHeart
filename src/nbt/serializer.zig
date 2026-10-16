const std = @import("std");
const tag_mod = @import("tag.zig");
const Tag = tag_mod.Tag;
const TagType = tag_mod.TagType;

pub const SerializerError = error{
    InvalidStringLength,
    InvalidListLength,
    InvalidArrayLength,
    MismatchedListElementType,
};

/// Запись именованного тега NBT (стандартный формат файлов и NBT до 1.20.2)
pub fn writeNamed(writer: anytype, name: []const u8, tag: Tag) !void {
    const tag_type: TagType = tag;
    try writer.writeByte(@intFromEnum(tag_type));
    if (tag_type == .end) return;

    if (name.len > std.math.maxInt(u16)) return SerializerError.InvalidStringLength;
    try writer.writeInt(u16, @as(u16, @intCast(name.len)), .big);
    try writer.writeAll(name);

    try writePayload(writer, tag);
}

/// Запись анонимного тега NBT (сетевой протокол Minecraft 1.20.2+)
pub fn writeAnonymous(writer: anytype, tag: Tag) !void {
    const tag_type: TagType = tag;
    try writer.writeByte(@intFromEnum(tag_type));
    if (tag_type == .end) return;

    try writePayload(writer, tag);
}

/// Запись полезной нагрузки тега без заголовка типа и имени
pub fn writePayload(writer: anytype, tag: Tag) !void {
    switch (tag) {
        .end => {},
        .byte => |b| {
            try writer.writeByte(@bitCast(b));
        },
        .short => |s| {
            try writer.writeInt(i16, s, .big);
        },
        .int => |i| {
            try writer.writeInt(i32, i, .big);
        },
        .long => |l| {
            try writer.writeInt(i64, l, .big);
        },
        .float => |f| {
            try writer.writeInt(u32, @as(u32, @bitCast(f)), .big);
        },
        .double => |d| {
            try writer.writeInt(u64, @as(u64, @bitCast(d)), .big);
        },
        .byte_array => |arr| {
            if (arr.len > std.math.maxInt(i32)) return SerializerError.InvalidArrayLength;
            try writer.writeInt(i32, @as(i32, @intCast(arr.len)), .big);
            try writer.writeAll(arr);
        },
        .string => |str| {
            if (str.len > std.math.maxInt(u16)) return SerializerError.InvalidStringLength;
            try writer.writeInt(u16, @as(u16, @intCast(str.len)), .big);
            try writer.writeAll(str);
        },
        .list => |l| {
            if (l.items.len > std.math.maxInt(i32)) return SerializerError.InvalidListLength;
            try writer.writeByte(@intFromEnum(l.elem_type));
            try writer.writeInt(i32, @as(i32, @intCast(l.items.len)), .big);
            for (l.items) |item| {
                const item_type: TagType = item;
                if (l.elem_type != .end and item_type != l.elem_type) {
                    return SerializerError.MismatchedListElementType;
                }
                try writePayload(writer, item);
            }
        },
        .compound => |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                const child_tag = entry.value_ptr.*;
                const child_type: TagType = child_tag;
                if (child_type == .end) continue;

                try writer.writeByte(@intFromEnum(child_type));
                const key = entry.key_ptr.*;
                if (key.len > std.math.maxInt(u16)) return SerializerError.InvalidStringLength;
                try writer.writeInt(u16, @as(u16, @intCast(key.len)), .big);
                try writer.writeAll(key);
                try writePayload(writer, child_tag);
            }
            // Маркер окончания TAG_End
            try writer.writeByte(@intFromEnum(TagType.end));
        },
        .int_array => |arr| {
            if (arr.len > std.math.maxInt(i32)) return SerializerError.InvalidArrayLength;
            try writer.writeInt(i32, @as(i32, @intCast(arr.len)), .big);
            for (arr) |val| {
                try writer.writeInt(i32, val, .big);
            }
        },
        .long_array => |arr| {
            if (arr.len > std.math.maxInt(i32)) return SerializerError.InvalidArrayLength;
            try writer.writeInt(i32, @as(i32, @intCast(arr.len)), .big);
            for (arr) |val| {
                try writer.writeInt(i64, val, .big);
            }
        },
    }
}

test "Сериализация NBT Named и Anonymous" {
    const allocator = std.testing.allocator;
    var root = Tag.createCompound();
    defer root.deinit(allocator);

    try root.putString(allocator, "author", "Notch");
    try root.putInt(allocator, "id", 42);

    var buf_named = std.ArrayList(u8).init(allocator);
    defer buf_named.deinit();
    try writeNamed(buf_named.writer(), "root", root);

    // Первым байтом должен быть TAG_Compound (10)
    try std.testing.expectEqual(@as(u8, 10), buf_named.items[0]);
    // Длина имени "root" (4)
    try std.testing.expectEqual(@as(u8, 0), buf_named.items[1]);
    try std.testing.expectEqual(@as(u8, 4), buf_named.items[2]);
    try std.testing.expectEqualStrings("root", buf_named.items[3..7]);

    var buf_anon = std.ArrayList(u8).init(allocator);
    defer buf_anon.deinit();
    try writeAnonymous(buf_anon.writer(), root);

    // Первым байтом должен быть TAG_Compound (10), сразу за ним поля без имени корня
    try std.testing.expectEqual(@as(u8, 10), buf_anon.items[0]);
    // Следующий байт - тип первого тега внутри compound (не 0)
    try std.testing.expect(buf_anon.items[1] != 0);
}
