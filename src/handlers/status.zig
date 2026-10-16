const std = @import("std");
const types = @import("../protocol/types.zig");
const packet = @import("../protocol/packet.zig");
const server = @import("../net/server.zig");
const login = @import("login.zig");


pub const PROTOCOL_VERSION: i32 = 774;
pub const VERSION_NAME: []const u8 = "1.21.11";

/// Обработка пакета Handshake (ID 0x00)
pub fn handleHandshake(client: *server.Client, pkt: *const packet.Packet) !void {
    if (pkt.id != 0x00) {
        return error.UnexpectedPacket;
    }

    var stream = pkt.reader();
    const r = stream.reader();

    const proto_ver = try types.readVarInt(r);
    client.protocol_version = proto_ver;

    // Пропускаем адрес сервера (до 255 байт) без бесполезной аллокации памяти
    const host_len_i32 = try types.readVarInt(r);
    if (host_len_i32 < 0 or host_len_i32 > 255) return types.ProtocolError.StringTooLong;
    try r.skipBytes(@as(usize, @intCast(host_len_i32)), .{});
    // Читаем порт сервера (u16)
    const port = try r.readInt(u16, .big);
    _ = port;

    // Следующее состояние (1 = Status, 2 = Login, 3 = Transfer)
    const next_state = try types.readVarInt(r);

    switch (next_state) {
        1 => {
            client.state = .status;
        },
        2 => {
            // Версионный гейт: сервер строго 1.21.11 (Протокол 774)
            if (proto_ver != PROTOCOL_VERSION) {
                std.debug.print("[ХЭНДШЕЙК] Отклонение клиента с несовместимой версией протокола: {d} (требуется {d})\n", .{ proto_ver, PROTOCOL_VERSION });
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "Несовместимая версия клиента! Требуется Minecraft {s} (Протокол {d}).", .{ VERSION_NAME, PROTOCOL_VERSION }) catch "Несовместимая версия клиента!";
                try login.sendLoginDisconnect(client, err_msg);
                return;
            }
            client.state = .login;
        },
        else => {
            std.debug.print("[ХЭНДШЕЙК] Неизвестное следующее состояние: {d}. Закрытие соединения.\n", .{next_state});
            client.state = .disconnected;
            return;
        },
    }
}

/// Обработка пакетов фазы Status (ID 0x00 - Status Request, ID 0x01 - Ping Request)
pub fn handleStatus(client: *server.Client, pkt: *const packet.Packet) !void {
    switch (pkt.id) {
        0x00 => {
            // Экранирование спецсимволов MOTD для валидного JSON без лимита и без усечения
            var escaped_motd = std.ArrayList(u8).init(client.arena.allocator());
            for (client.server_config.motd) |c| {
                switch (c) {
                    '"' => try escaped_motd.appendSlice("\\\""),
                    '\\' => try escaped_motd.appendSlice("\\\\"),
                    '\n' => try escaped_motd.appendSlice("\\n"),
                    '\r' => try escaped_motd.appendSlice("\\r"),
                    '\t' => try escaped_motd.appendSlice("\\t"),
                    else => try escaped_motd.append(c),
                }
            }

            var json_buf: [4096]u8 = undefined;
            const motd_json = try std.fmt.bufPrint(&json_buf,
                \\{{"version":{{"name":"{s}","protocol":{d}}},"players":{{"max":{d},"online":0,"sample":[]}},"description":{{"text":"{s}"}}}}
            , .{ VERSION_NAME, PROTOCOL_VERSION, client.server_config.max_players, escaped_motd.items });

            var pw = packet.PacketWriter.init(client.arena.allocator(), 0x00);
            try pw.writeString(motd_json);
            try client.sendPacket(&pw);
        },
        0x01 => {
            var stream = pkt.reader();
            const timestamp = try stream.reader().readInt(i64, .big);

            var pw = packet.PacketWriter.init(client.arena.allocator(), 0x01);
            try pw.writeI64(timestamp);
            try client.sendPacket(&pw);

            // После Ping/Pong клиент Minecraft закрывает соединение
            client.state = .disconnected;
        },
        else => {
            std.debug.print("[СТАТУС] Неожиданный пакет в фазе Status: 0x{X:0>2}\n", .{pkt.id});
        },
    }
}

// =================== Тесты фазы Status ===================

test "Handshake парсинг для Status и Login" {
    // Тест перехода в Status
    {
        var dummy_stream_buf = std.ArrayList(u8).init(std.testing.allocator);
        defer dummy_stream_buf.deinit();

        // Подготовим сырой пакет Handshake: proto=774, host="localhost", port=3222, next_state=1
        var fbs_buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&fbs_buf);
        try types.writeVarInt(fbs.writer(), 774);
        try types.writeString(fbs.writer(), "localhost");
        try fbs.writer().writeInt(u16, 3222, .big);
        try types.writeVarInt(fbs.writer(), 1);

        const pkt = packet.Packet{
            .id = 0x00,
            .payload = fbs.getWritten(),
        };

        const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
        const pipe_fds = try std.posix.pipe();
        defer std.posix.close(pipe_fds[0]);
        defer std.posix.close(pipe_fds[1]);

        var c = server.Client.init(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator);

        defer c.arena.deinit();

        try handleHandshake(&c, &pkt);
        try std.testing.expectEqual(server.ConnectionState.status, c.state);
        try std.testing.expectEqual(@as(i32, 774), c.protocol_version);
    }
}

test "Версионный гейт и экранирование JSON MOTD" {
    // 1. Тест версионного гейта: клиент с протоколом 769 отклоняется
    {
        var fbs_buf: [128]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&fbs_buf);
        try types.writeVarInt(fbs.writer(), 769); // Неверная версия
        try types.writeString(fbs.writer(), "localhost");
        try fbs.writer().writeInt(u16, 3222, .big);
        try types.writeVarInt(fbs.writer(), 2); // Login

        const pkt = packet.Packet{ .id = 0x00, .payload = fbs.getWritten() };
        const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
        const pipe_fds = try std.posix.pipe();
        defer std.posix.close(pipe_fds[0]);
        defer std.posix.close(pipe_fds[1]);

        var c = server.Client.init(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator);
        defer c.arena.deinit();

        try handleHandshake(&c, &pkt);
        try std.testing.expectEqual(server.ConnectionState.disconnected, c.state);
    }

    // 2. Тест экранирования кавычек в MOTD
    {
        const custom_cfg = server.ServerConfig{
            .motd = "Сервер \"Zig\" 1.21.11 | C:\\Games",
        };
        const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
        const pipe_fds = try std.posix.pipe();
        defer std.posix.close(pipe_fds[0]);
        defer std.posix.close(pipe_fds[1]);

        var c = server.Client.initWithConfig(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator, &custom_cfg, null);
        defer c.arena.deinit();

        const status_pkt = packet.Packet{ .id = 0x00, .payload = &[_]u8{} };
        try handleStatus(&c, &status_pkt);

        // Читаем отправленный статус из pipe и парсим JSON
        const pipe_stream = std.net.Stream{ .handle = pipe_fds[0] };
        const resp_pkt = try packet.readPacket(pipe_stream.reader(), std.testing.allocator, 65536);
        defer {
            const raw_ptr: [*]const u8 = resp_pkt.payload.ptr - types.varIntSize(resp_pkt.id);
            const raw_len = resp_pkt.payload.len + types.varIntSize(resp_pkt.id);
            std.testing.allocator.free(raw_ptr[0..raw_len]);
        }

        var stream = resp_pkt.reader();
        const json_str = try types.readString(stream.reader(), std.testing.allocator, 4096);
        defer std.testing.allocator.free(json_str);

        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("description") != null);
    }
}
