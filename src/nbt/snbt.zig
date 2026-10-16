const std = @import("std");
const tag_mod = @import("tag.zig");
const Tag = tag_mod.Tag;

/// Сериализация NBT тега в строковый формат SNBT (Stringified NBT)
pub fn formatSnbt(tag: Tag, writer: anytype) !void {
    switch (tag) {
        .end => {},
        .byte => |b| {
            try writer.print("{d}b", .{b});
        },
        .short => |s| {
            try writer.print("{d}s", .{s});
        },
        .int => |i| {
            try writer.print("{d}", .{i});
        },
        .long => |l| {
            try writer.print("{d}L", .{l});
        },
        .float => |f| {
            try writer.print("{d}f", .{f});
        },
        .double => |d| {
            try writer.print("{d}d", .{d});
        },
        .string => |str| {
            try writer.writeByte('"');
            for (str) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeByte('"');
        },
        .byte_array => |arr| {
            try writer.writeAll("[B;");
            for (arr, 0..) |b, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.print("{d}b", .{@as(i8, @bitCast(b))});
            }
            try writer.writeByte(']');
        },
        .int_array => |arr| {
            try writer.writeAll("[I;");
            for (arr, 0..) |val, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.print("{d}", .{val});
            }
            try writer.writeByte(']');
        },
        .long_array => |arr| {
            try writer.writeAll("[L;");
            for (arr, 0..) |val, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.print("{d}L", .{val});
            }
            try writer.writeByte(']');
        },
        .list => |l| {
            try writer.writeByte('[');
            for (l.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try formatSnbt(item, writer);
            }
            try writer.writeByte(']');
        },
        .compound => |map| {
            try writer.writeByte('{');
            var it = map.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) {
                    try writer.writeByte(',');
                }
                first = false;

                // Запись ключа
                const key = entry.key_ptr.*;
                var needs_quotes = false;
                for (key) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') {
                        needs_quotes = true;
                        break;
                    }
                }
                if (needs_quotes or key.len == 0) {
                    try writer.writeByte('"');
                    for (key) |c| {
                        if (c == '"' or c == '\\') try writer.writeByte('\\');
                        try writer.writeByte(c);
                    }
                    try writer.writeByte('"');
                } else {
                    try writer.writeAll(key);
                }

                try writer.writeByte(':');
                try formatSnbt(entry.value_ptr.*, writer);
            }
            try writer.writeByte('}');
        },
    }
}

/// Выделение строки SNBT в аллокаторе
pub fn toSnbtAlloc(allocator: std.mem.Allocator, tag: Tag) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try formatSnbt(tag, list.writer());
    return list.toOwnedSlice();
}

test "Форматирование SNBT" {
    const allocator = std.testing.allocator;
    var root = Tag.createCompound();
    defer root.deinit(allocator);

    try root.putByte(allocator, "flag", 1);
    try root.putString(allocator, "title", "Hello \"World\"");

    const str = try toSnbtAlloc(allocator, root);
    defer allocator.free(str);

    try std.testing.expect(std.mem.indexOf(u8, str, "flag:1b") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "title:\"Hello \\\"World\\\"\"") != null);
}
