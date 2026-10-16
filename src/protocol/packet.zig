const std = @import("std");
const types = @import("types.zig");
pub const nbt = @import("../nbt/nbt.zig");

/// Представление входящего распакованного пакета
pub const Packet = struct {
    id: i32,
    payload: []const u8,

    pub fn reader(self: *const Packet) std.io.FixedBufferStream([]const u8) {
        return std.io.fixedBufferStream(self.payload);
    }
};

/// Сборщик исходящего пакета с автоматическим подсчетом длины
pub const PacketWriter = struct {
    packet_id: i32,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, packet_id: i32) PacketWriter {
        return .{
            .packet_id = packet_id,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *PacketWriter) void {
        self.buffer.deinit();
    }

    pub fn clear(self: *PacketWriter, packet_id: i32) void {
        self.packet_id = packet_id;
        self.buffer.clearRetainingCapacity();
    }

    pub fn writer(self: *PacketWriter) std.ArrayList(u8).Writer {
        return self.buffer.writer();
    }

    pub fn writeVarInt(self: *PacketWriter, value: i32) !void {
        try types.writeVarInt(self.writer(), value);
    }

    pub fn writeVarLong(self: *PacketWriter, value: i64) !void {
        try types.writeVarLong(self.writer(), value);
    }

    pub fn writeString(self: *PacketWriter, str: []const u8) !void {
        try types.writeString(self.writer(), str);
    }

    pub fn writeU8(self: *PacketWriter, value: u8) !void {
        try self.writer().writeByte(value);
    }

    pub fn writeI8(self: *PacketWriter, value: i8) !void {
        try self.writer().writeByte(@bitCast(value));
    }

    pub fn writeBool(self: *PacketWriter, value: bool) !void {
        try self.writer().writeByte(if (value) 1 else 0);
    }

    pub fn writeI16(self: *PacketWriter, value: i16) !void {
        try self.writer().writeInt(i16, value, .big);
    }

    pub fn writeU16(self: *PacketWriter, value: u16) !void {
        try self.writer().writeInt(u16, value, .big);
    }

    pub fn writeI32(self: *PacketWriter, value: i32) !void {
        try self.writer().writeInt(i32, value, .big);
    }

    pub fn writeI64(self: *PacketWriter, value: i64) !void {
        try self.writer().writeInt(i64, value, .big);
    }

    pub fn writeF32(self: *PacketWriter, value: f32) !void {
        try self.writer().writeInt(u32, @as(u32, @bitCast(value)), .big);
    }

    pub fn writeF64(self: *PacketWriter, value: f64) !void {
        try self.writer().writeInt(u64, @as(u64, @bitCast(value)), .big);
    }

    pub fn writeBytes(self: *PacketWriter, bytes: []const u8) !void {
        try self.writer().writeAll(bytes);
    }

    pub fn writeUUID(self: *PacketWriter, uuid: [16]u8) !void {
        try self.writer().writeAll(&uuid);
    }

    pub fn writePosition(self: *PacketWriter, pos: types.Position) !void {
        try pos.write(self.writer());
    }

    pub fn writeNbt(self: *PacketWriter, tag: nbt.Tag) !void {
        try nbt.writeAnonymous(self.writer(), tag);
    }

    pub fn writeNamedNbt(self: *PacketWriter, name: []const u8, tag: nbt.Tag) !void {
        try nbt.writeNamed(self.writer(), name, tag);
    }

    /// Отправка сформированного пакета в поток без сжатия
    pub fn send(self: *const PacketWriter, out: anytype) !void {
        try self.sendWithCompression(out, std.heap.page_allocator, -1);
    }

    /// Отправка пакета с поддержкой сжатия (zlib deflate при достижении порога)
    pub fn sendWithCompression(self: *const PacketWriter, out: anytype, allocator: std.mem.Allocator, threshold: i32) !void {
        const id_size = types.varIntSize(self.packet_id);
        const uncompressed_size = id_size + self.buffer.items.len;

        if (threshold >= 0) {
            if (uncompressed_size >= @as(usize, @intCast(threshold))) {
                // Порог превышен: сжимаем zlib
                var compressed_payload = std.ArrayList(u8).init(allocator);
                defer compressed_payload.deinit();

                var compressor = try std.compress.zlib.compressor(compressed_payload.writer(), .{});
                try types.writeVarInt(compressor.writer(), self.packet_id);
                try compressor.writer().writeAll(self.buffer.items);
                try compressor.finish();

                const data_len_varint_size = types.varIntSize(@as(i32, @intCast(uncompressed_size)));
                const packet_length = @as(i32, @intCast(data_len_varint_size + compressed_payload.items.len));

                try types.writeVarInt(out, packet_length);
                try types.writeVarInt(out, @as(i32, @intCast(uncompressed_size)));
                try out.writeAll(compressed_payload.items);
            } else {
                // Порог не превышен: data_length = 0 (1 байт)
                const packet_length = @as(i32, @intCast(1 + uncompressed_size));
                try types.writeVarInt(out, packet_length);
                try types.writeVarInt(out, 0);
                try types.writeVarInt(out, self.packet_id);
                try out.writeAll(self.buffer.items);
            }
        } else {
            // Без сжатия: Total Length + Packet ID + Data
            const total_packet_len = @as(i32, @intCast(uncompressed_size));
            try types.writeVarInt(out, total_packet_len);
            try types.writeVarInt(out, self.packet_id);
            try out.writeAll(self.buffer.items);
        }
    }
};

/// Чтение пакета с поддержкой сжатия zlib
pub fn readPacketCompressed(reader: anytype, allocator: std.mem.Allocator, max_packet_size: usize, threshold: i32) !Packet {
    const packet_len_i32 = try types.readVarInt(reader);
    if (packet_len_i32 <= 0) return types.ProtocolError.InvalidPacketLength;
    const packet_len = @as(usize, @intCast(packet_len_i32));
    if (packet_len > max_packet_size) return types.ProtocolError.InvalidPacketLength;

    if (threshold >= 0) {
        const data_len_i32 = try types.readVarInt(reader);
        const data_len_size = types.varIntSize(data_len_i32);
        if (data_len_size > packet_len) return types.ProtocolError.InvalidPacketLength;
        const remaining_len = packet_len - data_len_size;

        if (data_len_i32 == 0) {
            // Пакет меньше порога — тело не сжато
            const raw_buf = try allocator.alloc(u8, remaining_len);
            errdefer allocator.free(raw_buf);
            try reader.readNoEof(raw_buf);

            var fbs = std.io.fixedBufferStream(raw_buf);
            const packet_id = try types.readVarInt(fbs.reader());
            return Packet{
                .id = packet_id,
                .payload = raw_buf[fbs.pos..],
            };
        } else {
            // Пакет сжат zlib
            const compressed_buf = try allocator.alloc(u8, remaining_len);
            defer allocator.free(compressed_buf);
            try reader.readNoEof(compressed_buf);

            var fbs = std.io.fixedBufferStream(compressed_buf);
            var decompressor = std.compress.zlib.decompressor(fbs.reader());

            const decompressed_buf = try allocator.alloc(u8, @as(usize, @intCast(data_len_i32)));
            errdefer allocator.free(decompressed_buf);
            var read_idx: usize = 0;
            while (read_idx < decompressed_buf.len) {
                const n = try decompressor.read(decompressed_buf[read_idx..]);
                if (n == 0) break;
                read_idx += n;
            }

            var decomp_fbs = std.io.fixedBufferStream(decompressed_buf);
            const packet_id = try types.readVarInt(decomp_fbs.reader());
            return Packet{
                .id = packet_id,
                .payload = decompressed_buf[decomp_fbs.pos..],
            };
        }
    } else {
        const raw_buf = try allocator.alloc(u8, packet_len);
        errdefer allocator.free(raw_buf);
        try reader.readNoEof(raw_buf);

        var fbs = std.io.fixedBufferStream(raw_buf);
        const packet_id = try types.readVarInt(fbs.reader());
        return Packet{
            .id = packet_id,
            .payload = raw_buf[fbs.pos..],
        };
    }
}

/// Чтение входящего пакета из reader'а (без сжатия)
pub fn readPacket(reader: anytype, allocator: std.mem.Allocator, max_packet_size: usize) !Packet {
    return readPacketCompressed(reader, allocator, max_packet_size, -1);
}


// =================== Тесты пакетов ===================

test "PacketWriter и readPacket сквозное тестирование" {
    var pw = PacketWriter.init(std.testing.allocator, 0x02);
    defer pw.deinit();

    try pw.writeString("Player1");
    try pw.writeI32(100);
    try pw.writeBool(true);

    var stream_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stream_buf.deinit();

    try pw.send(stream_buf.writer());

    var read_stream = std.io.fixedBufferStream(stream_buf.items);
    const packet = try readPacket(read_stream.reader(), std.testing.allocator, 65536);
    // raw_buf аллоцирован, но payload указывает на его срез
    // Для освобождения raw_buf найдем начало
    const raw_buf_ptr: [*]const u8 = packet.payload.ptr - types.varIntSize(packet.id);
    const raw_buf_len = packet.payload.len + types.varIntSize(packet.id);
    defer std.testing.allocator.free(raw_buf_ptr[0..raw_buf_len]);

    try std.testing.expectEqual(@as(i32, 0x02), packet.id);

    var payload_stream = packet.reader();
    const name = try types.readString(payload_stream.reader(), std.testing.allocator, 64);
    defer std.testing.allocator.free(name);
    const score = try payload_stream.reader().readInt(i32, .big);
    const flag = (try payload_stream.reader().readByte()) != 0;

    try std.testing.expectEqualStrings("Player1", name);
    try std.testing.expectEqual(@as(i32, 100), score);
    try std.testing.expectEqual(true, flag);
}

test "Сжатие пакетов zlib и порядок слоев: encrypt(compress(packet))" {
    const crypto = @import("../crypto/crypto.zig");
    const allocator = std.testing.allocator;

    // 1. Создаем большой тестовый пакет (больше порога 256 байт)
    var pw = PacketWriter.init(allocator, 0x30);
    defer pw.deinit();

    const sample_chunk_data = [_]u8{0xAB} ** 1024;
    try pw.writeBytes(&sample_chunk_data);

    // 2. Отправляем со сжатием (порог 256) в промежуточный буфер: compress(packet)
    var compressed_stream = std.ArrayList(u8).init(allocator);
    defer compressed_stream.deinit();

    try pw.sendWithCompression(compressed_stream.writer(), allocator, 256);

    // Размер сжатого пакета должен быть значительно меньше 1024 благодаря zlib
    try std.testing.expect(compressed_stream.items.len < 100);

    // 3. Шифруем сжатый буфер: encrypt(compress(packet))
    const key = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var enc_cipher = crypto.Cfb8Cipher.init(key);
    var dec_cipher = crypto.Cfb8Cipher.init(key);

    const wire_bytes = try allocator.dupe(u8, compressed_stream.items);
    defer allocator.free(wire_bytes);
    enc_cipher.encrypt(wire_bytes);

    // Убеждаемся, что данные в проводе зашифрованы
    try std.testing.expect(!std.mem.eql(u8, wire_bytes, compressed_stream.items));

    // 4. Приемная сторона: сначала расшифровка сокета, затем распаковка: decompress(decrypt(packet))
    dec_cipher.decrypt(wire_bytes);
    try std.testing.expectEqualSlices(u8, compressed_stream.items, wire_bytes);

    var reader_fbs = std.io.fixedBufferStream(wire_bytes);
    const recv_packet = try readPacketCompressed(reader_fbs.reader(), allocator, 65536, 256);
    defer {
        const raw_ptr: [*]const u8 = recv_packet.payload.ptr - types.varIntSize(recv_packet.id);
        const raw_len = recv_packet.payload.len + types.varIntSize(recv_packet.id);
        allocator.free(raw_ptr[0..raw_len]);
    }

    try std.testing.expectEqual(@as(i32, 0x30), recv_packet.id);
    try std.testing.expectEqualSlices(u8, &sample_chunk_data, recv_packet.payload);
}
