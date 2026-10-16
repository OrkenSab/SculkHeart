const std = @import("std");
const types = @import("../protocol/types.zig");
const packet = @import("../protocol/packet.zig");
const server = @import("../net/server.zig");
const chunk = @import("../world/chunk.zig");

pub const PACKET_ID_LOGIN_PLAY: i32 = 0x30;
pub const PACKET_ID_GAME_EVENT: i32 = 0x26;
pub const PACKET_ID_CHUNK_DATA: i32 = 0x2C;
pub const PACKET_ID_PLAYER_POSITION: i32 = 0x46;
pub const PACKET_ID_KEEP_ALIVE: i32 = 0x2B;

/// Инициализация игрока в мире: отправка Login (play), Game Event 13, чанка (0, 0) и координат
pub fn startPlay(client: *server.Client) !void {
    client.last_keep_alive_ack = std.time.milliTimestamp();
    // 1. Отправка пакета Login (play)
    {
        var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_LOGIN_PLAY);

        try pw.writeI32(1); // Entity ID: 1
        try pw.writeBool(false); // isHardcore: false

        // worldNames: ["minecraft:overworld"]
        try pw.writeVarInt(1);
        try pw.writeString("minecraft:overworld");

        try pw.writeVarInt(client.server_config.max_players); // maxPlayers
        try pw.writeVarInt(client.server_config.view_distance); // viewDistance
        try pw.writeVarInt(client.server_config.view_distance); // simulationDistance
        try pw.writeBool(false); // reducedDebugInfo: false
        try pw.writeBool(true); // enableRespawnScreen: true
        try pw.writeBool(false); // doLimitedCrafting: false

        // worldState (SpawnInfo)
        try pw.writeVarInt(0); // dimension: 0 (minecraft:overworld)
        try pw.writeString("minecraft:overworld");
        try pw.writeI64(0); // hashedSeed: 0
        const gamemode_byte: i8 = if (std.mem.eql(u8, client.server_config.gamemode, "survival"))
            0
        else if (std.mem.eql(u8, client.server_config.gamemode, "creative"))
            1
        else if (std.mem.eql(u8, client.server_config.gamemode, "adventure"))
            2
        else if (std.mem.eql(u8, client.server_config.gamemode, "spectator"))
            3
        else
            1;
        try pw.writeI8(gamemode_byte);
        try pw.writeU8(255); // previousGamemode: -1 (нет)
        try pw.writeBool(false); // isDebug: false
        try pw.writeBool(true); // isFlat: true
        try pw.writeBool(false); // death: none
        try pw.writeVarInt(0); // portalCooldown: 0
        try pw.writeVarInt(63); // seaLevel: 63

        try pw.writeBool(false); // enforcesSecureChat: false

        try client.sendPacket(&pw);
    }

    // 2. Отправка Game Event (13 = Start waiting for chunks, 0.0f)
    {
        var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_GAME_EVENT);
        try pw.writeU8(13); // Event: 13
        try pw.writeF32(0.0); // Value: 0.0f
        try client.sendPacket(&pw);
    }

    // 3. Установка радиуса и центра чанков согласно view_distance
    const R: i32 = std.math.clamp(client.server_config.view_distance, 2, 16);
    {
        // Set Chunk Cache Radius (ID 0x5D)
        var pw_radius = packet.PacketWriter.init(client.arena.allocator(), 0x5D);
        try pw_radius.writeVarInt(R);
        try client.sendPacket(&pw_radius);
        // Set Chunk Cache Center (ID 0x5C, chunk 0, 0)
        var pw_center = packet.PacketWriter.init(client.arena.allocator(), 0x5C);
        try pw_center.writeVarInt(0);
        try pw_center.writeVarInt(0);
        try client.sendPacket(&pw_center);
    }

    // 4. Отправка пакета начала пакета чанков (Chunk Batch Start ID 0x0C)
    {
        var pw_batch_start = packet.PacketWriter.init(client.arena.allocator(), 0x0C);
        try client.sendPacket(&pw_batch_start);
    }

    // 5. Отправка сетки плоских чанков согласно радиусу R
    {
        var template = try chunk.ChunkGenerator.buildChunkPacket(client.arena.allocator(), PACKET_ID_CHUNK_DATA, 0, 0);

        var count: i32 = 0;
        var cx: i32 = -R;
        while (cx <= R) : (cx += 1) {
            var cz: i32 = -R;
            while (cz <= R) : (cz += 1) {
                std.mem.writeInt(i32, template.buffer.items[0..4], cx, .big);
                std.mem.writeInt(i32, template.buffer.items[4..8], cz, .big);
                try client.sendPacket(&template);
                count += 1;
            }
        }

        // 6. Завершение пакета чанков (Chunk Batch Finished ID 0x0B)
        var pw_batch_end = packet.PacketWriter.init(client.arena.allocator(), 0x0B);
        try pw_batch_end.writeVarInt(count);
        try client.sendPacket(&pw_batch_end);
    }
    // 4. Синхронизация позиции игрока (Телепортация на блок травы)
    {
        var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_PLAYER_POSITION);

        client.teleport_id = 1;
        try pw.writeVarInt(client.teleport_id);
        try pw.writeF64(client.server_config.spawn_x);
        try pw.writeF64(client.server_config.spawn_y);
        try pw.writeF64(client.server_config.spawn_z);
        try pw.writeF64(0.0); // dx: 0.0
        try pw.writeF64(0.0); // dy: 0.0
        try pw.writeF64(0.0); // dz: 0.0
        try pw.writeF32(0.0); // yaw: 0.0
        try pw.writeF32(0.0); // pitch: 0.0
        try pw.writeI32(0); // flags: 0 (абсолютные координаты)

        try client.sendPacket(&pw);
    }

    std.debug.print("[ИГРА] Игрок '{s}' успешно вошел в плоский мир (координаты: {d:.1}, {d:.1}, {d:.1}, {s}).\n", .{
        client.getUsername(),
        client.server_config.spawn_x,
        client.server_config.spawn_y,
        client.server_config.spawn_z,
        client.server_config.gamemode,
    });
}

/// Отправка Keep Alive клиенту
pub fn sendKeepAlive(client: *server.Client) !void {
    const keep_alive_id = PACKET_ID_KEEP_ALIVE;
    const ts = std.time.milliTimestamp();
    client.keep_alive_id = ts;

    var pw = packet.PacketWriter.init(client.arena.allocator(), keep_alive_id);
    try pw.writeI64(ts);
    try client.sendPacket(&pw);
}

/// Обработка пакетов в фазе Play
pub fn handlePlay(client: *server.Client, pkt: *const packet.Packet) !void {
    switch (pkt.id) {
        0x00 => {
            // Confirm Teleportation
            var stream = pkt.reader();
            const confirmed_id = types.readVarInt(stream.reader()) catch 0;
            std.debug.print("[ИГРА] Игрок '{s}' подтвердил телепортацию #{d}.\n", .{ client.getUsername(), confirmed_id });
        },
        0x1A, 0x1B, 0x1C => {
            // Keep Alive (serverbound)
            client.last_keep_alive_ack = std.time.milliTimestamp();
        },
        0x0C, 0x1D, 0x1E, 0x1F, 0x20, 0x2B => {
            // Пакеты движения (move_player), тиков (client_tick_end) и готовности (player_loaded)
        },
        else => {
            // Игнорируем остальные пакеты игры
        },
    }
}

// =================== Тесты фазы Play ===================

test "Проверка формирования пакетов Play" {
    const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);

    const drain_thread = try std.Thread.spawn(.{}, struct {
        fn drain(fd: std.posix.fd_t) void {
            var b: [4096]u8 = undefined;
            while (true) {
                const n = std.posix.read(fd, &b) catch break;
                if (n == 0) break;
            }
        }
    }.drain, .{pipe_fds[0]});
    defer {
        std.posix.close(pipe_fds[1]);
        drain_thread.join();
    }
    var c = server.Client.init(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator);
    defer c.arena.deinit();
    c.setUsername("PlayerPlay");
    c.protocol_version = 774;

    try startPlay(&c);
    try sendKeepAlive(&c);

    // Подтверждение телепортации
    var fbs_buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&fbs_buf);
    try types.writeVarInt(fbs.writer(), 1);

    const confirm_pkt = packet.Packet{ .id = 0x00, .payload = fbs.getWritten() };
    try handlePlay(&c, &confirm_pkt);
}
