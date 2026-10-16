const std = @import("std");
const types = @import("../protocol/types.zig");
const packet = @import("../protocol/packet.zig");
const nbt = @import("../nbt/nbt.zig");

/// Генератор плоского чанка (бедрок, 3 слоя земли, слой травы, остальное воздух)
pub const ChunkGenerator = struct {
    /// Сериализация данных блоков всех 24 секций чанка (Y от -64 до 319)
    pub fn buildChunkData(allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const w = buf.writer();

        // Секция 0: Y = -64..-49 (16 блоков в высоту)
        // Y=-64: бедрок (16x16 = 256 блоков)
        // Y=-63..-61: земля (3 слоя * 256 = 768 блоков)
        // Y=-60: трава (256 блоков)
        // Всего не-воздуха: 256 + 768 + 256 = 1280 блоков
        {
            // 1. block_count (i16)
            try w.writeInt(i16, 1280, .big);

            // 2. block_states PalettedContainer:
            // bits_per_entry: 4 (косвенная палитра)
            try w.writeByte(4);

            // Длина палитры: 4 записи
            try types.writeVarInt(w, 4);
            try types.writeVarInt(w, 0); // 0: воздух (minecraft:air = 0)
            try types.writeVarInt(w, 79); // 1: бедрок (minecraft:bedrock = 79 в 1.21.11)
            try types.writeVarInt(w, 10); // 2: земля (minecraft:dirt = 10)
            try types.writeVarInt(w, 9); // 3: блок травы (minecraft:grass_block = 9)


            // Слой y=0 (бедрок -> индекс палитры 1): 16 longs
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                try w.writeInt(u64, 0x1111111111111111, .big);
            }
            // Слои y=1..3 (земля -> индекс палитры 2): 48 longs
            i = 0;
            while (i < 48) : (i += 1) {
                try w.writeInt(u64, 0x2222222222222222, .big);
            }
            // Слой y=4 (трава -> индекс палитры 3): 16 longs
            i = 0;
            while (i < 16) : (i += 1) {
                try w.writeInt(u64, 0x3333333333333333, .big);
            }
            // Слои y=5..15 (воздух -> индекс палитры 0): 176 longs
            i = 0;
            while (i < 176) : (i += 1) {
                try w.writeInt(u64, 0x0000000000000000, .big);
            }

            // 3. biomes PalettedContainer:
            // bits_per_entry = 0 (одно значение на всю секцию)
            try w.writeByte(0);
            try types.writeVarInt(w, 0); // 0 longs
        }

        // Секции 1..23: Y = -48..319 (полностью воздух)
        var sec: usize = 1;
        while (sec < 24) : (sec += 1) {
            // block_count = 0
            try w.writeInt(i16, 0, .big);

            try w.writeByte(0);
            try types.writeVarInt(w, 0); // воздух

            try w.writeByte(0);
            try types.writeVarInt(w, 0);
        }

        return buf.toOwnedSlice();
    }
    /// Построение NBT-дерева карты высот (Heightmaps: MOTION_BLOCKING и WORLD_SURFACE)
    pub fn buildHeightmapsNbt(allocator: std.mem.Allocator) !nbt.Tag {
        var root = nbt.Tag.createCompound();
        errdefer root.deinit(allocator);

        // В плоском мире высота блоков от дна Y=-64: бедрок (1) + 3 слоя земли (3) + трава (1) = 5 блоков
        // Массив из 37 longs (256 элементов по 9 бит, упакованных в 64-битные числа)
        const heightmap_longs = try allocator.alloc(i64, 37);
        errdefer allocator.free(heightmap_longs);
        // Первые 36 longs упаковывают по 7 значений (36 * 7 = 252 элемента)
        for (heightmap_longs[0..36]) |*l| {
            l.* = @bitCast(@as(u64, 0x0140a05028140a05));
        }
        // 37-й long упаковывает оставшиеся 4 элемента (256 - 252 = 4)
        heightmap_longs[36] = @bitCast(@as(u64, 0x0000000028140a05));
        try root.put(allocator, "MOTION_BLOCKING", nbt.Tag{ .long_array = heightmap_longs });

        const surface_longs = try allocator.dupe(i64, heightmap_longs);
        errdefer allocator.free(surface_longs);
        try root.put(allocator, "WORLD_SURFACE", nbt.Tag{ .long_array = surface_longs });

        return root;
    }


    /// Формирование полного пакета Chunk Data and Update Light
    pub fn buildChunkPacket(allocator: std.mem.Allocator, packet_id: i32, chunk_x: i32, chunk_z: i32) !packet.PacketWriter {
        var pw = packet.PacketWriter.init(allocator, packet_id);

        // 1. Chunk X и Chunk Z
        try pw.writeI32(chunk_x);
        try pw.writeI32(chunk_z);

        // 2. Heightmaps (в Minecraft 1.21.5+ / 1.21.11 протокол 774 это Map<VarInt, long[]>)
        // Передаем VarInt 0 (размер Map = 0), клиент вычисляет карты высот самостоятельно
        try pw.writeVarInt(0);

        // 3. Chunk Data (с префиксом длины VarInt)
        const chunk_data = try buildChunkData(allocator);
        defer allocator.free(chunk_data);

        try pw.writeVarInt(@as(i32, @intCast(chunk_data.len)));
        try pw.writeBytes(chunk_data);

        // 4. Block Entities (длина 0)
        try pw.writeVarInt(0);

        // 5. Light Data: полнолучевой солнечный свет (уровень 15) для всех 26 секций
        const full_light = [_]u8{0xFF} ** 2048;
        const light_mask: u64 = 0x03FFFFFF; // 26 бит установлены (секции от Y=-80 до Y=335)

        // skyLightMask (BitSet из 1 long)
        try pw.writeVarInt(1);
        try pw.writeI64(@bitCast(light_mask));

        // blockLightMask (пустой)
        try pw.writeVarInt(0);

        // emptySkyLightMask (пустой)
        try pw.writeVarInt(0);

        // emptyBlockLightMask (все 26 секций без искусственного света = 0)
        try pw.writeVarInt(1);
        try pw.writeI64(@bitCast(light_mask));

        // 26 массивов солнечного света по 2048 байт (максимальная яркость 15)
        try pw.writeVarInt(26);
        var s_idx: usize = 0;
        while (s_idx < 26) : (s_idx += 1) {
            try pw.writeVarInt(2048);
            try pw.writeBytes(&full_light);
        }

        // 0 массивов блочного света
        try pw.writeVarInt(0);
        return pw;
    }
};

test "Генерация плоского чанка и проверка структуры данных" {
    const data = try ChunkGenerator.buildChunkData(std.testing.allocator);
    defer std.testing.allocator.free(data);

    // Размер данных чанка должен быть валидным и ненулевым
    try std.testing.expect(data.len > 2000);

    var pw = try ChunkGenerator.buildChunkPacket(std.testing.allocator, 0x2E, 0, 0);
    defer pw.deinit();

    try std.testing.expect(pw.buffer.items.len > data.len);

    // Проверяем, что в начале пакета записан VarInt 0 (пустой Map карт высот)
    // Смещение: 4 байта ChunkX + 4 байта ChunkZ = 8
    var fbs = std.io.fixedBufferStream(pw.buffer.items[8..]);
    const heightmap_map_size = try types.readVarInt(fbs.reader());
    try std.testing.expectEqual(@as(i32, 0), heightmap_map_size);

    // Проверяем генерацию NBT карт высот отдельно
    var heightmaps = try ChunkGenerator.buildHeightmapsNbt(std.testing.allocator);
    defer heightmaps.deinit(std.testing.allocator);
    const mb = heightmaps.get("MOTION_BLOCKING").?;
    try std.testing.expectEqual(@as(usize, 37), mb.long_array.len);
    const ws = heightmaps.get("WORLD_SURFACE").?;
    try std.testing.expectEqual(@as(usize, 37), ws.long_array.len);
}
