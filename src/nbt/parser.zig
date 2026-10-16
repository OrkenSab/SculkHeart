const std = @import("std");
const tag_mod = @import("tag.zig");
const Tag = tag_mod.Tag;
const TagType = tag_mod.TagType;
const NbtList = tag_mod.NbtList;

pub const ParserError = error{
    InvalidTagType,
    InvalidArrayLength,
    InvalidListLength,
    RecursionLimitExceeded,
    MismatchedListElementType,
    EndOfStream,
    OutOfMemory,
    NotCompound,
};

pub const MAX_DEPTH: usize = 512;
pub const MAX_STRING_LEN: usize = 65535;
pub const MAX_ARRAY_LEN: usize = 16 * 1024 * 1024; // 16 MB ограничение на размер массивов

/// Результат парсинга именованного NBT
pub const NamedNbt = struct {
    name: []const u8,
    root: Tag,

    pub fn deinit(self: *NamedNbt, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.root.deinit(allocator);
    }
};

/// Парсинг именованного тега NBT
pub fn parseNamed(reader: anytype, allocator: std.mem.Allocator) !NamedNbt {
    const type_byte = reader.readByte() catch |err| {
        if (err == error.EndOfStream) return ParserError.EndOfStream;
        return err;
    };
    if (type_byte > 12) return ParserError.InvalidTagType;
    const root_type: TagType = @enumFromInt(type_byte);

    if (root_type == .end) {
        return NamedNbt{
            .name = try allocator.dupe(u8, ""),
            .root = Tag{ .end = {} },
        };
    }

    const name_len = try reader.readInt(u16, .big);
    const name = try allocator.alloc(u8, name_len);
    errdefer allocator.free(name);
    try reader.readNoEof(name);

    var root = try parsePayload(reader, allocator, root_type, 0);
    errdefer root.deinit(allocator);

    return NamedNbt{
        .name = name,
        .root = root,
    };
}

/// Парсинг анонимного тега NBT (протокол 1.20.2+)
pub fn parseAnonymous(reader: anytype, allocator: std.mem.Allocator) !Tag {
    const type_byte = reader.readByte() catch |err| {
        if (err == error.EndOfStream) return ParserError.EndOfStream;
        return err;
    };
    if (type_byte > 12) return ParserError.InvalidTagType;
    const root_type: TagType = @enumFromInt(type_byte);

    if (root_type == .end) {
        return Tag{ .end = {} };
    }

    return try parsePayload(reader, allocator, root_type, 0);
}

/// Внутренний рекурсивный парсер полезной нагрузки NBT
pub fn parsePayload(reader: anytype, allocator: std.mem.Allocator, tag_type: TagType, depth: usize) ParserError!Tag {
    if (depth > MAX_DEPTH) return ParserError.RecursionLimitExceeded;

    return switch (tag_type) {
        .end => Tag{ .end = {} },
        .byte => Tag{ .byte = @bitCast(try readByte(reader)) },
        .short => Tag{ .short = try readIntBig(i16, reader) },
        .int => Tag{ .int = try readIntBig(i32, reader) },
        .long => Tag{ .long = try readIntBig(i64, reader) },
        .float => {
            const raw_u32 = try readIntBig(u32, reader);
            return Tag{ .float = @bitCast(raw_u32) };
        },
        .double => {
            const raw_u64 = try readIntBig(u64, reader);
            return Tag{ .double = @bitCast(raw_u64) };
        },
        .byte_array => {
            const len_i32 = try readIntBig(i32, reader);
            if (len_i32 < 0) return ParserError.InvalidArrayLength;
            const len = @as(usize, @intCast(len_i32));
            if (len > MAX_ARRAY_LEN) return ParserError.InvalidArrayLength;

            const buf = allocator.alloc(u8, len) catch return ParserError.OutOfMemory;
            errdefer allocator.free(buf);
            readFull(reader, buf) catch |err| return err;
            return Tag{ .byte_array = buf };
        },
        .string => {
            const len = try readIntBig(u16, reader);
            const buf = allocator.alloc(u8, len) catch return ParserError.OutOfMemory;
            errdefer allocator.free(buf);
            readFull(reader, buf) catch |err| return err;
            return Tag{ .string = buf };
        },
        .list => {
            const elem_type_byte = try readByte(reader);
            if (elem_type_byte > 12) return ParserError.InvalidTagType;
            const elem_type: TagType = @enumFromInt(elem_type_byte);

            const len_i32 = try readIntBig(i32, reader);
            if (len_i32 < 0) return ParserError.InvalidListLength;
            const len = @as(usize, @intCast(len_i32));
            if (len > MAX_ARRAY_LEN) return ParserError.InvalidListLength;

            if (len == 0) {
                return Tag{
                    .list = NbtList{
                        .elem_type = elem_type,
                        .items = &[_]Tag{},
                    },
                };
            }

            if (elem_type == .end and len > 0) {
                return ParserError.InvalidTagType;
            }

            const items = allocator.alloc(Tag, len) catch return ParserError.OutOfMemory;
            var initialized_count: usize = 0;
            errdefer {
                for (items[0..initialized_count]) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            }

            for (0..len) |i| {
                items[i] = try parsePayload(reader, allocator, elem_type, depth + 1);
                initialized_count += 1;
            }

            return Tag{
                .list = NbtList{
                    .elem_type = elem_type,
                    .items = items,
                },
            };
        },
        .compound => {
            var comp = Tag.createCompound();
            errdefer comp.deinit(allocator);

            while (true) {
                const child_type_byte = try readByte(reader);
                if (child_type_byte > 12) return ParserError.InvalidTagType;
                const child_type: TagType = @enumFromInt(child_type_byte);

                if (child_type == .end) {
                    break;
                }

                const key_len = try readIntBig(u16, reader);
                const key = allocator.alloc(u8, key_len) catch return ParserError.OutOfMemory;
                errdefer allocator.free(key);
                readFull(reader, key) catch |err| return err;

                var child_val = try parsePayload(reader, allocator, child_type, depth + 1);
                errdefer child_val.deinit(allocator);

                try comp.putOwned(allocator, key, child_val);
            }

            return comp;
        },
        .int_array => {
            const len_i32 = try readIntBig(i32, reader);
            if (len_i32 < 0) return ParserError.InvalidArrayLength;
            const len = @as(usize, @intCast(len_i32));
            if (len > MAX_ARRAY_LEN / 4) return ParserError.InvalidArrayLength;

            const arr = allocator.alloc(i32, len) catch return ParserError.OutOfMemory;
            errdefer allocator.free(arr);

            for (0..len) |i| {
                arr[i] = try readIntBig(i32, reader);
            }

            return Tag{ .int_array = arr };
        },
        .long_array => {
            const len_i32 = try readIntBig(i32, reader);
            if (len_i32 < 0) return ParserError.InvalidArrayLength;
            const len = @as(usize, @intCast(len_i32));
            if (len > MAX_ARRAY_LEN / 8) return ParserError.InvalidArrayLength;

            const arr = allocator.alloc(i64, len) catch return ParserError.OutOfMemory;
            errdefer allocator.free(arr);

            for (0..len) |i| {
                arr[i] = try readIntBig(i64, reader);
            }

            return Tag{ .long_array = arr };
        },
    };
}

fn readByte(reader: anytype) ParserError!u8 {
    return reader.readByte() catch |err| {
        if (err == error.EndOfStream) return ParserError.EndOfStream;
        return ParserError.EndOfStream;
    };
}

fn readIntBig(comptime T: type, reader: anytype) ParserError!T {
    return reader.readInt(T, .big) catch |err| {
        if (err == error.EndOfStream) return ParserError.EndOfStream;
        return ParserError.EndOfStream;
    };
}

fn readFull(reader: anytype, buf: []u8) ParserError!void {
    reader.readNoEof(buf) catch |err| {
        if (err == error.EndOfStream) return ParserError.EndOfStream;
        return ParserError.EndOfStream;
    };
}

test "Парсинг и Round-trip NBT (Named и Anonymous)" {
    const serializer = @import("serializer.zig");
    const allocator = std.testing.allocator;

    var original = Tag.createCompound();
    defer original.deinit(allocator);

    try original.putByte(allocator, "testByte", 123);
    try original.putShort(allocator, "testShort", 32000);
    try original.putInt(allocator, "testInt", 12345678);
    try original.putLong(allocator, "testLong", 98765432101234);
    try original.putFloat(allocator, "testFloat", 3.14159);
    try original.putDouble(allocator, "testDouble", 2.718281828459);
    try original.putString(allocator, "testString", "Привет, Майнкрафт на Zig!");

    const byte_slice = try allocator.dupe(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    try original.put(allocator, "testByteArray", Tag{ .byte_array = byte_slice });

    const int_slice = try allocator.dupe(i32, &[_]i32{ 10, 20, 30, -40, 50 });
    try original.put(allocator, "testIntArray", Tag{ .int_array = int_slice });

    const long_slice = try allocator.dupe(i64, &[_]i64{ 100000000000, -200000000000 });
    try original.put(allocator, "testLongArray", Tag{ .long_array = long_slice });

    // Вложенный Compound
    var sub = Tag.createCompound();
    try sub.putString(allocator, "subKey", "subValue");
    try original.put(allocator, "subCompound", sub);

    // 1. Named NBT Round-trip
    var stream_named = std.ArrayList(u8).init(allocator);
    defer stream_named.deinit();

    try serializer.writeNamed(stream_named.writer(), "TestRoot", original);

    var read_fbs_named = std.io.fixedBufferStream(stream_named.items);
    var parsed_named = try parseNamed(read_fbs_named.reader(), allocator);
    defer parsed_named.deinit(allocator);

    try std.testing.expectEqualStrings("TestRoot", parsed_named.name);
    try std.testing.expectEqual(@as(?i8, 123), parsed_named.root.getByte("testByte"));
    try std.testing.expectEqual(@as(?i32, 12345678), parsed_named.root.getInt("testInt"));
    try std.testing.expectEqual(@as(?i64, 98765432101234), parsed_named.root.getLong("testLong"));
    try std.testing.expectEqualStrings("Привет, Майнкрафт на Zig!", parsed_named.root.getString("testString").?);

    const sub_parsed = parsed_named.root.get("subCompound").?;
    try std.testing.expectEqualStrings("subValue", sub_parsed.getString("subKey").?);

    // 2. Anonymous NBT Round-trip
    var stream_anon = std.ArrayList(u8).init(allocator);
    defer stream_anon.deinit();

    try serializer.writeAnonymous(stream_anon.writer(), original);

    var read_fbs_anon = std.io.fixedBufferStream(stream_anon.items);
    var parsed_anon = try parseAnonymous(read_fbs_anon.reader(), allocator);
    defer parsed_anon.deinit(allocator);

    try std.testing.expectEqual(@as(?i8, 123), parsed_anon.getByte("testByte"));
    try std.testing.expectEqual(@as(?i32, 12345678), parsed_anon.getInt("testInt"));
    try std.testing.expectEqualStrings("Привет, Майнкрафт на Zig!", parsed_anon.getString("testString").?);
}
