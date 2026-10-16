const std = @import("std");

/// Ошибки при чтении и записи сетевых примитивов Minecraft
pub const ProtocolError = error{
    VarIntTooBig,
    VarLongTooBig,
    StringTooLong,
    EndOfStream,
    InvalidPacketLength,
};

/// Чтение VarInt (до 5 байт)
pub fn readVarInt(reader: anytype) !i32 {
    var value: u32 = 0;
    var shift: u32 = 0;
    while (true) {
        if (shift >= 35) return ProtocolError.VarIntTooBig;
        const byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        if (shift < 32) {
            value |= @as(u32, byte & 0x7F) << @as(u5, @truncate(shift));
        } else {
            const val_bits = @as(u32, byte & 0x7F);
            if ((val_bits & 0x70) != 0) return ProtocolError.VarIntTooBig;
            value |= val_bits << @as(u5, @truncate(shift));
        }
        if ((byte & 0x80) == 0) break;
        shift += 7;
    }
    return @bitCast(value);
}

/// Запись VarInt в writer
pub fn writeVarInt(writer: anytype, value: i32) !void {
    var val: u32 = @bitCast(value);
    while (true) {
        if ((val & ~@as(u32, 0x7F)) == 0) {
            try writer.writeByte(@truncate(val));
            return;
        }
        try writer.writeByte(@truncate((val & 0x7F) | 0x80));
        val >>= 7;
    }
}

/// Подсчет количества байтов, необходимых для кодирования VarInt
pub fn varIntSize(value: i32) usize {
    var val: u32 = @bitCast(value);
    var size: usize = 0;
    while (true) {
        size += 1;
        val >>= 7;
        if (val == 0) break;
    }
    return size;
}

/// Чтение VarLong (до 10 байт)
pub fn readVarLong(reader: anytype) !i64 {
    var value: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (shift >= 70) return ProtocolError.VarLongTooBig;
        const byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        if (shift < 64) {
            value |= @as(u64, byte & 0x7F) << @as(u6, @truncate(shift));
        } else {
            const val_bits = @as(u64, byte & 0x7F);
            if ((val_bits & 0x7E) != 0) return ProtocolError.VarLongTooBig;
            value |= val_bits << @as(u6, @truncate(shift));
        }
        if ((byte & 0x80) == 0) break;
        shift += 7;
    }
    return @bitCast(value);
}

/// Запись VarLong в writer
pub fn writeVarLong(writer: anytype, value: i64) !void {
    var val: u64 = @bitCast(value);
    while (true) {
        if ((val & ~@as(u64, 0x7F)) == 0) {
            try writer.writeByte(@truncate(val));
            return;
        }
        try writer.writeByte(@truncate((val & 0x7F) | 0x80));
        val >>= 7;
    }
}

/// Чтение строки со счетчиком байт в формате VarInt
pub fn readString(reader: anytype, allocator: std.mem.Allocator, max_len: usize) ![]u8 {
    const len_i32 = try readVarInt(reader);
    if (len_i32 < 0) return ProtocolError.InvalidPacketLength;
    const len = @as(usize, @intCast(len_i32));
    if (len > max_len) return ProtocolError.StringTooLong;

    const buffer = try allocator.alloc(u8, len);
    errdefer allocator.free(buffer);

    try reader.readNoEof(buffer);
    return buffer;
}

/// Запись строки с VarInt длиной
pub fn writeString(writer: anytype, str: []const u8) !void {
    try writeVarInt(writer, @as(i32, @intCast(str.len)));
    try writer.writeAll(str);
}

/// Minecraft Position (x 26 бит, z 26 бит, y 12 бит со знаком)
pub const Position = struct {
    x: i32,
    y: i16,
    z: i32,

    pub fn pack(self: Position) u64 {
        const ux = @as(u64, @bitCast(@as(i64, self.x))) & 0x3FFFFFF;
        const uz = @as(u64, @bitCast(@as(i64, self.z))) & 0x3FFFFFF;
        const uy = @as(u64, @bitCast(@as(i64, self.y))) & 0xFFF;
        return (ux << 38) | (uz << 12) | uy;
    }

    pub fn unpack(val: u64) Position {
        var x_raw = @as(i64, @bitCast(val >> 38));
        if (x_raw >= (1 << 25)) x_raw -= (1 << 26);

        var y_raw = @as(i64, @bitCast(val & 0xFFF));
        if (y_raw >= (1 << 11)) y_raw -= (1 << 12);

        var z_raw = @as(i64, @bitCast((val >> 12) & 0x3FFFFFF));
        if (z_raw >= (1 << 25)) z_raw -= (1 << 26);

        return .{
            .x = @as(i32, @intCast(x_raw)),
            .y = @as(i16, @intCast(y_raw)),
            .z = @as(i32, @intCast(z_raw)),
        };
    }

    pub fn write(self: Position, writer: anytype) !void {
        try writer.writeInt(u64, self.pack(), .big);
    }

    pub fn read(reader: anytype) !Position {
        const val = try reader.readInt(u64, .big);
        return unpack(val);
    }
};

// =================== Тесты примитивов ===================

test "VarInt кодирование и декодирование стандартных тестовых векторов" {
    const test_cases = [_]struct { val: i32, expected: []const u8 }{
        .{ .val = 0, .expected = &[_]u8{0x00} },
        .{ .val = 1, .expected = &[_]u8{0x01} },
        .{ .val = 2, .expected = &[_]u8{0x02} },
        .{ .val = 127, .expected = &[_]u8{0x7F} },
        .{ .val = 128, .expected = &[_]u8{ 0x80, 0x01 } },
        .{ .val = 255, .expected = &[_]u8{ 0xFF, 0x01 } },
        .{ .val = 25565, .expected = &[_]u8{ 0xDD, 0xC7, 0x01 } },
        .{ .val = 2097151, .expected = &[_]u8{ 0xFF, 0xFF, 0x7F } },
        .{ .val = 2147483647, .expected = &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x07 } },
        .{ .val = -1, .expected = &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } },
        .{ .val = -2147483648, .expected = &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x08 } },
    };

    for (test_cases) |tc| {
        var buf: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try writeVarInt(fbs.writer(), tc.val);
        const encoded = fbs.getWritten();

        try std.testing.expectEqualSlices(u8, tc.expected, encoded);
        try std.testing.expectEqual(tc.expected.len, varIntSize(tc.val));

        var read_fbs = std.io.fixedBufferStream(encoded);
        const decoded = try readVarInt(read_fbs.reader());
        try std.testing.expectEqual(tc.val, decoded);
    }
}

test "String запись и чтение" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const test_str = "Привет, Minecraft 1.21.11!";
    try writeString(fbs.writer(), test_str);

    var read_fbs = std.io.fixedBufferStream(fbs.getWritten());
    const decoded = try readString(read_fbs.reader(), std.testing.allocator, 100);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(test_str, decoded);
}

test "Position упаковка и распаковка" {
    const pos = Position{ .x = 12345, .y = -60, .z = -67890 };
    const packed_pos = pos.pack();
    const unpacked = Position.unpack(packed_pos);

    try std.testing.expectEqual(pos.x, unpacked.x);
    try std.testing.expectEqual(pos.y, unpacked.y);
    try std.testing.expectEqual(pos.z, unpacked.z);
}

test "Защита от переполнения VarInt и VarLong при мусорных данных" {
    // 6 байт с установленным старшим битом (атака переполнением shift)
    const mal_varint = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    var fbs_vi = std.io.fixedBufferStream(&mal_varint);
    try std.testing.expectError(ProtocolError.VarIntTooBig, readVarInt(fbs_vi.reader()));

    // 11 байт для VarLong
    const mal_varlong = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    var fbs_vl = std.io.fixedBufferStream(&mal_varlong);
    try std.testing.expectError(ProtocolError.VarLongTooBig, readVarLong(fbs_vl.reader()));
}
