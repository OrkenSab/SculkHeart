const std = @import("std");

pub const tag = @import("tag.zig");
pub const serializer = @import("serializer.zig");
pub const parser = @import("parser.zig");
pub const snbt = @import("snbt.zig");

pub const Tag = tag.Tag;
pub const TagType = tag.TagType;
pub const NbtList = tag.NbtList;
pub const NbtCompound = tag.NbtCompound;

pub const writeNamed = serializer.writeNamed;
pub const writeAnonymous = serializer.writeAnonymous;
pub const writePayload = serializer.writePayload;

pub const parseNamed = parser.parseNamed;
pub const parseAnonymous = parser.parseAnonymous;
pub const NamedNbt = parser.NamedNbt;

pub const formatSnbt = snbt.formatSnbt;

test "Полное покрытие всех 12 типов NBT и форматирование SNBT" {
    const allocator = std.testing.allocator;
    var root = Tag.createCompound();
    defer root.deinit(allocator);

    // 1. byte
    try root.putByte(allocator, "t_byte", -12);
    // 2. short
    try root.putShort(allocator, "t_short", 32000);
    // 3. int
    try root.putInt(allocator, "t_int", -1234567);
    // 4. long
    try root.putLong(allocator, "t_long", 9000000000000000);
    // 5. float
    try root.putFloat(allocator, "t_float", 12.34);
    // 6. double
    try root.putDouble(allocator, "t_double", -56.789);
    // 7. byte_array
    const raw_bytes = try allocator.dupe(u8, &[_]u8{ 1, 2, 3, 255 });
    try root.put(allocator, "t_byte_array", Tag{ .byte_array = raw_bytes });
    // 8. string
    try root.putString(allocator, "t_string", "Строка с пробелами и \"кавычками\"");
    // 9. list
    const list_items = try allocator.alloc(Tag, 3);
    list_items[0] = Tag{ .int = 100 };
    list_items[1] = Tag{ .int = 200 };
    list_items[2] = Tag{ .int = 300 };
    try root.put(allocator, "t_list", Tag{ .list = .{ .elem_type = .int, .items = list_items } });
    // 10. compound
    var nested = Tag.createCompound();
    try nested.putString(allocator, "nested_k", "nested_v");
    try root.put(allocator, "t_compound", nested);
    // 11. int_array
    const ints = try allocator.dupe(i32, &[_]i32{ -10, 0, 10 });
    try root.put(allocator, "t_int_array", Tag{ .int_array = ints });
    // 12. long_array
    const longs = try allocator.dupe(i64, &[_]i64{ -9999999999, 9999999999 });
    try root.put(allocator, "t_long_array", Tag{ .long_array = longs });

    // Проверка Named NBT
    var out_bytes = std.ArrayList(u8).init(allocator);
    defer out_bytes.deinit();
    try writeNamed(out_bytes.writer(), "MinecraftRoot", root);

    var stream = std.io.fixedBufferStream(out_bytes.items);
    var parsed = try parseNamed(stream.reader(), allocator);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("MinecraftRoot", parsed.name);
    try std.testing.expectEqual(@as(?i8, -12), parsed.root.getByte("t_byte"));
    try std.testing.expectEqual(@as(?i32, -1234567), parsed.root.getInt("t_int"));
    try std.testing.expectEqual(@as(?i64, 9000000000000000), parsed.root.getLong("t_long"));

    // Проверка SNBT
    const snbt_str = try toSnbtAlloc(allocator, root);
    defer allocator.free(snbt_str);
    try std.testing.expect(std.mem.indexOf(u8, snbt_str, "t_byte:-12b") != null);
    try std.testing.expect(std.mem.indexOf(u8, snbt_str, "t_int:-1234567") != null);
    try std.testing.expect(std.mem.indexOf(u8, snbt_str, "[I;-10,0,10]") != null);
}
pub const toSnbtAlloc = snbt.toSnbtAlloc;

test {
    std.testing.refAllDecls(@This());
}
