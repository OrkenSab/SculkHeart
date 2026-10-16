const std = @import("std");
const types = @import("../protocol/types.zig");
const packet = @import("../protocol/packet.zig");
const server = @import("../net/server.zig");
const crypto = @import("../crypto/crypto.zig");

/// Генерация стандартного UUID для оффлайн-режима Minecraft (v3 MD5)
pub fn generateOfflinePlayerUuid(name: []const u8) [16]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("OfflinePlayer:");
    md5.update(name);
    var out: [16]u8 = undefined;
    md5.final(&out);
    out[6] = (out[6] & 0x0f) | 0x30; // Версия UUID: 3
    out[8] = (out[8] & 0x3f) | 0x80; // Вариант: IETF RFC 4122
    return out;
}

/// Отправка пакета Disconnect в фазе Login (ID 0x00)
pub fn sendLoginDisconnect(client: *server.Client, reason_text: []const u8) !void {
    var pw = packet.PacketWriter.init(client.arena.allocator(), 0x00);
    var json_buf: [512]u8 = undefined;
    const json_str = try std.fmt.bufPrint(&json_buf, "{{\"text\":\"{s}\"}}", .{reason_text});
    try pw.writeString(json_str);
    try client.sendPacket(&pw);
    client.state = .disconnected;
}

/// Отправка Set Compression (если включено в конфиге) и Login Success (ID 0x02)
pub fn sendLoginSuccess(client: *server.Client) !void {
    if (client.server_config.compression_threshold >= 0) {
        // Отправка пакета Set Compression (ID 0x03) в фазе Login
        // ВАЖНО: Сам пакет Set Compression отправляется клиенту еще без сжатия!
        var pw_comp = packet.PacketWriter.init(client.arena.allocator(), 0x03);
        try pw_comp.writeVarInt(client.server_config.compression_threshold);

        if (client.enc_cipher) |*c| {
            var raw_buf = std.ArrayList(u8).init(client.arena.allocator());
            try pw_comp.sendWithCompression(raw_buf.writer(), client.arena.allocator(), -1);
            c.encrypt(raw_buf.items);
            try client.stream.writer().writeAll(raw_buf.items);
        } else {
            try pw_comp.sendWithCompression(client.stream.writer(), client.arena.allocator(), -1);
        }

        // Активируем порог сжатия на клиенте для всех последующих пакетов
        client.compression_threshold = client.server_config.compression_threshold;
        std.debug.print("[СЖАТИЕ] Отправлен пакет Set Compression (порог {d} байт) игроку '{s}'.\n", .{ client.compression_threshold, client.getUsername() });
    }

    // Отправляем Login Success (ID 0x02)
    var pw = packet.PacketWriter.init(client.arena.allocator(), 0x02);
    try pw.writeUUID(client.uuid);
    try pw.writeString(client.getUsername());
    try pw.writeVarInt(0); // 0 свойств профиля
    try client.sendPacket(&pw);
}

/// Верификация сессии игрока через Mojang Session Server
pub fn verifyMojangSession(client: *server.Client, server_hash: []const u8) !?[16]u8 {
    var http_client = std.http.Client{ .allocator = client.arena.allocator() };
    defer http_client.deinit();

    var url_buf: [1024]u8 = undefined;
    const url_str = try std.fmt.bufPrint(&url_buf, "{s}?username={s}&serverId={s}", .{
        client.server_config.auth_url,
        client.getUsername(),
        server_hash,
    });

    const uri = std.Uri.parse(url_str) catch |err| {
        std.debug.print("[АВТОРИЗАЦИЯ] Ошибка парсинга URL авторизации: {s} ({any})\n", .{ url_str, err });
        return null;
    };

    var resp_body = std.ArrayList(u8).init(client.arena.allocator());
    defer resp_body.deinit();

    const fetch_res = http_client.fetch(.{
        .location = .{ .uri = uri },
        .response_storage = .{ .dynamic = &resp_body },
    }) catch |err| {
        std.debug.print("[АВТОРИЗАЦИЯ] Не удалось связаться с серверами авторизации Mojang: {any}\n", .{err});
        return null;
    };

    if (fetch_res.status != .ok) {
        std.debug.print("[АВТОРИЗАЦИЯ] Сервер Mojang вернул HTTP статус: {d}\n", .{@intFromEnum(fetch_res.status)});
        return null;
    }

    // Парсим ответ JSON: {"id":"069a79f444e94726a5bef2a2fce1b293","name":"Steve",...}
    const parsed_json = std.json.parseFromSlice(
        std.json.Value,
        client.arena.allocator(),
        resp_body.items,
        .{},
    ) catch |err| {
        std.debug.print("[АВТОРИЗАЦИЯ] Ошибка парсинга JSON профиля Mojang: {any}\n", .{err});
        return null;
    };
    defer parsed_json.deinit();

    const root_obj = switch (parsed_json.value) {
        .object => |obj| obj,
        else => return null,
    };

    const id_val = root_obj.get("id") orelse return null;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return null,
    };

    if (id_str.len != 32) return null;

    var uuid: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&uuid, id_str) catch return null;

    std.debug.print("[АВТОРИЗАЦИЯ] Сессия игрока '{s}' подтверждена Mojang (UUID: {s})\n", .{ client.getUsername(), id_str });
    return uuid;
}

/// Обработка пакетов фазы Login
pub fn handleLogin(client: *server.Client, pkt: *const packet.Packet) !void {
    switch (pkt.id) {
        0x00 => {
            // Login Start:
            // 1. Имя игрока (String до 16 байт)
            // 2. Player UUID (16 байт)
            var stream = pkt.reader();
            const r = stream.reader();

            const username = types.readString(r, client.arena.allocator(), 16) catch {
                try sendLoginDisconnect(client, "Некорректный формат имени игрока");
                return;
            };

            // Валидация имени игрока Minecraft: длина 3..16 и только символы [A-Za-z0-9_]
            if (username.len < 3 or username.len > 16) {
                std.debug.print("[АВТОРИЗАЦИЯ] Отклонен вход: недопустимая длина имени '{s}' ({d} симв.)\n", .{ username, username.len });
                try sendLoginDisconnect(client, "Длина имени игрока должна быть от 3 до 16 символов");
                return;
            }
            for (username) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                    std.debug.print("[АВТОРИЗАЦИЯ] Отклонен вход: недопустимый символ '{c}' в имени '{s}'\n", .{ c, username });
                    try sendLoginDisconnect(client, "Недопустимые символы в имени (разрешены только латиница, цифры и '_')");
                    return;
                }
            }
            client.setUsername(username);
            var uuid: [16]u8 = undefined;
            const read_bytes = try r.readAll(&uuid);
            if (read_bytes < 16 or std.mem.allEqual(u8, &uuid, 0)) {
                uuid = generateOfflinePlayerUuid(username);
            }
            client.uuid = uuid;

            std.debug.print("[АВТОРИЗАЦИЯ] Запрос входа игрока: '{s}'\n", .{client.getUsername()});

            // Если включен Online-Mode и доступны ключи RSA — начинаем процедуру шифрования
            if (client.server_config.online_mode and client.rsa_keys != null) {
                std.crypto.random.bytes(&client.verify_token);

                // Отправляем Encryption Request (ID 0x01):
                // 1. Server ID (String, пустая строка "")
                // 2. Public Key Length (VarInt) + Public Key (DER)
                // 3. Verify Token Length (VarInt = 4) + Verify Token (4 байта)
                const pub_der = client.rsa_keys.?.public_key_der;
                var pw = packet.PacketWriter.init(client.arena.allocator(), 0x01);
                try pw.writeString(""); // Server ID
                try pw.writeVarInt(@as(i32, @intCast(pub_der.len)));
                try pw.writeBytes(pub_der);
                try pw.writeVarInt(4);
                try pw.writeBytes(&client.verify_token);

                std.debug.print("[АВТОРИЗАЦИЯ] Отправка Encryption Request (0x01) игроку '{s}'.\n", .{client.getUsername()});
                try client.sendPacket(&pw);
                return;
            }

            // В оффлайн-режиме отправляем Set Compression (если активно) и Login Success (0x02)
            try sendLoginSuccess(client);
        },
        0x01 => {
            // Encryption Response (0x01)
            var stream = pkt.reader();
            const r = stream.reader();

            const shared_secret_len = try types.readVarInt(r);
            if (shared_secret_len <= 0 or shared_secret_len > 1024) {
                try sendLoginDisconnect(client, "Некорректный размер секретного ключа");
                return;
            }
            const enc_secret = try client.arena.allocator().alloc(u8, @as(usize, @intCast(shared_secret_len)));
            try r.readNoEof(enc_secret);

            const verify_token_len = try types.readVarInt(r);
            if (verify_token_len <= 0 or verify_token_len > 1024) {
                try sendLoginDisconnect(client, "Некорректный размер проверочного токена");
                return;
            }
            const enc_verify_token = try client.arena.allocator().alloc(u8, @as(usize, @intCast(verify_token_len)));
            try r.readNoEof(enc_verify_token);

            const rsa_keys = client.rsa_keys orelse {
                try sendLoginDisconnect(client, "На сервере не настроены ключи шифрования");
                return;
            };

            // 1. Дешифруем токен верификации
            const decrypted_token = rsa_keys.decrypt(client.arena.allocator(), enc_verify_token) catch |err| {
                std.debug.print("[АВТОРИЗАЦИЯ] Ошибка дешифрования токена: {any}\n", .{err});
                try sendLoginDisconnect(client, "Ошибка проверки токена сессии");
                return;
            };

            if (decrypted_token.len != 4 or !std.mem.eql(u8, decrypted_token[0..4], &client.verify_token)) {
                std.debug.print("[АВТОРИЗАЦИЯ] Токен верификации не совпадает!\n", .{});
                try sendLoginDisconnect(client, "Неверный токен подтверждения сессии");
                return;
            }

            // 2. Дешифруем общий симметричный секрет (shared secret)
            const decrypted_secret = rsa_keys.decrypt(client.arena.allocator(), enc_secret) catch |err| {
                std.debug.print("[АВТОРИЗАЦИЯ] Ошибка дешифрования общего секрета: {any}\n", .{err});
                try sendLoginDisconnect(client, "Ошибка дешифрования ключа шифрования");
                return;
            };

            if (decrypted_secret.len != 16) {
                std.debug.print("[АВТОРИЗАЦИЯ] Размер общего секрета неверен ({d} != 16)\n", .{decrypted_secret.len});
                try sendLoginDisconnect(client, "Неверная длина симметричного ключа");
                return;
            }

            var shared_secret: [16]u8 = undefined;
            @memcpy(&shared_secret, decrypted_secret[0..16]);

            // 3. Вычисляем Minecraft SHA-1 хэш сессии
            const mc_hash = crypto.computeMinecraftHash("", &shared_secret, rsa_keys.public_key_der);
            std.debug.print("[АВТОРИЗАЦИЯ] Вычислен Minecraft-хэш сессии: '{s}'\n", .{mc_hash.slice()});

            // 4. Верифицируем сессию на серверах авторизации Mojang
            const verified_uuid = try verifyMojangSession(client, mc_hash.slice());
            if (verified_uuid) |u| {
                client.uuid = u;
            } else {
                try sendLoginDisconnect(client, "Не удалось связаться с серверами авторизации Mojang");
                return;
            }

            // 5. Включаем потоковое шифрование AES-128-CFB8 для сокета клиента
            client.enableEncryption(shared_secret);
            std.debug.print("[ШИФРОВАНИЕ] Шифрование AES-128-CFB8 успешно активировано для '{s}'.\n", .{client.getUsername()});

            // 6. Отправляем Set Compression (если активно) и Login Success (0x02) в зашифрованный канал
            try sendLoginSuccess(client);
        },
        0x03 => {
            // Login Acknowledged (ID 0x03):
            // Подтверждение от клиента об успешном получении Login Success
            std.debug.print("[АВТОРИЗАЦИЯ] Игрок '{s}' подтвердил вход, переход в фазу Configuration.\n", .{client.getUsername()});
            client.state = .configuration;
        },
        else => {
            std.debug.print("[АВТОРИЗАЦИЯ] Неожиданный пакет в фазе Login: 0x{X:0>2}\n", .{pkt.id});
        },
    }
}

// =================== Тесты фазы Login ===================

test "Генерация Offline UUID и обработка Login Start" {
    const uuid1 = generateOfflinePlayerUuid("Player1");
    try std.testing.expectEqual(@as(u8, 0x30), uuid1[6] & 0xF0);
    try std.testing.expectEqual(@as(u8, 0x80), uuid1[8] & 0xC0);

    const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    var c = server.Client.init(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator);
    defer c.arena.deinit();

    // Подготовим Login Start (ID 0x00)
    var fbs_buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&fbs_buf);
    try types.writeString(fbs.writer(), "Steve");
    try fbs.writer().writeAll(&std.mem.zeroes([16]u8));

    const pkt = packet.Packet{
        .id = 0x00,
        .payload = fbs.getWritten(),
    };

    try handleLogin(&c, &pkt);
    try std.testing.expectEqualStrings("Steve", c.getUsername());
}


fn mockMojangServer(net_server: *std.net.Server) void {
    const conn = net_server.accept() catch return;
    defer conn.stream.close();

    var buf: [1024]u8 = undefined;
    _ = conn.stream.read(&buf) catch return;

    const resp = "HTTP/1.1 200 OK\r\nContent-Length: 57\r\nContent-Type: application/json\r\n\r\n{\"id\":\"069a79f444e94726a5bef2a2fce1b293\",\"name\":\"Steve\"}";
    conn.stream.writeAll(resp) catch return;
}

test "Online-Mode: полный цикл рукопожатия шифрования (Encryption Request/Response -> AES CFB8)" {
    const allocator = std.testing.allocator;

    // 1. Инициализируем нативную ключевую пару RSA-2048
    const test_key_path = "test_login_rsa.key";
    const test_der_path = "test_login_rsa.der";
    defer {
        std.fs.cwd().deleteFile(test_key_path) catch {};
        std.fs.cwd().deleteFile(test_der_path) catch {};
    }
    var rsa_keys = try crypto.initOrLoadRsaKeys(allocator, test_key_path, test_der_path);
    defer rsa_keys.deinit();
    // 2. Запускаем локальный мок-сервер авторизации Mojang
    var srv_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var mock_net_server = try srv_addr.listen(.{});
    defer mock_net_server.deinit();

    const mock_port = mock_net_server.listen_address.in.getPort();
    const mock_thread = try std.Thread.spawn(.{}, mockMojangServer, .{&mock_net_server});
    defer mock_thread.join();

    var auth_url_buf: [128]u8 = undefined;
    const auth_url_str = try std.fmt.bufPrint(&auth_url_buf, "http://127.0.0.1:{d}/hasJoined", .{mock_port});

    const online_cfg = server.ServerConfig{
        .online_mode = true,
        .auth_url = auth_url_str,
    };

    // 3. Создаем клиента сервера
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    var c = server.Client.initWithConfig(.{ .handle = pipe_fds[1] }, srv_addr, allocator, &online_cfg, &rsa_keys);
    c.state = .login;
    defer c.arena.deinit();

    // 4. Отправляем Login Start (0x00)
    var fbs_buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&fbs_buf);
    try types.writeString(fbs.writer(), "Steve");
    try fbs.writer().writeAll(&std.mem.zeroes([16]u8));

    const pkt_start = packet.Packet{
        .id = 0x00,
        .payload = fbs.getWritten(),
    };

    try handleLogin(&c, &pkt_start);
    try std.testing.expectEqualStrings("Steve", c.getUsername());
    try std.testing.expectEqual(server.ConnectionState.login, c.state);

    // 5. Читаем Encryption Request (0x01) из pipe со стороны клиента
    const pipe_stream = std.net.Stream{ .handle = pipe_fds[0] };
    const enc_req_pkt = try packet.readPacket(pipe_stream.reader(), allocator, 65536);
    defer {
        const raw_buf_ptr: [*]const u8 = enc_req_pkt.payload.ptr - types.varIntSize(enc_req_pkt.id);
        const raw_buf_len = enc_req_pkt.payload.len + types.varIntSize(enc_req_pkt.id);
        allocator.free(raw_buf_ptr[0..raw_buf_len]);
    }

    try std.testing.expectEqual(@as(i32, 0x01), enc_req_pkt.id);
    var enc_req_stream = enc_req_pkt.reader();
    const r = enc_req_stream.reader();

    const srv_id = try types.readString(r, allocator, 64);
    defer allocator.free(srv_id);
    try std.testing.expectEqualStrings("", srv_id);

    const key_len = try types.readVarInt(r);
    const pub_key_bytes = try allocator.alloc(u8, @as(usize, @intCast(key_len)));
    defer allocator.free(pub_key_bytes);
    try r.readNoEof(pub_key_bytes);
    try std.testing.expectEqualStrings(rsa_keys.public_key_der, pub_key_bytes);

    const token_len = try types.readVarInt(r);
    try std.testing.expectEqual(@as(i32, 4), token_len);
    var recvd_token: [4]u8 = undefined;
    try r.readNoEof(&recvd_token);
    try std.testing.expectEqual(c.verify_token, recvd_token);

    // 6. Клиент генерирует 16 байт shared_secret и шифрует с помощью RSA
    const client_shared_secret = [16]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160 };
    // 6. Клиент генерирует 16 байт shared_secret и шифрует чистым нативным методом
    const encrypted_secret = try rsa_keys.encryptPkcs1v15(allocator, &client_shared_secret);
    const encrypted_token = try rsa_keys.encryptPkcs1v15(allocator, &recvd_token);

    // 7. Формируем пакет Encryption Response (ID 0x01)
    var resp_pw = packet.PacketWriter.init(allocator, 0x01);
    defer resp_pw.deinit();
    try resp_pw.writeVarInt(@as(i32, @intCast(encrypted_secret.len)));
    try resp_pw.writeBytes(&encrypted_secret);
    try resp_pw.writeVarInt(@as(i32, @intCast(encrypted_token.len)));
    try resp_pw.writeBytes(&encrypted_token);

    const resp_pkt = packet.Packet{
        .id = 0x01,
        .payload = resp_pw.buffer.items,
    };

    // 8. Сервер обрабатывает Encryption Response
    try handleLogin(&c, &resp_pkt);

    // Проверяем, что шифрование на сервере активировано
    try std.testing.expect(c.enc_cipher != null);
    try std.testing.expect(c.dec_cipher != null);

    // 9. Клиент принимает зашифрованный пакет Login Success (0x02) из pipe
    var client_dec_cipher = crypto.Cfb8Cipher.init(client_shared_secret);
    // Читаем сырые байты пакета
    var encrypted_success_buf: [256]u8 = undefined;
    const n_read = try pipe_stream.read(&encrypted_success_buf);
    try std.testing.expect(n_read > 0);

    // Расшифровываем клиентом
    client_dec_cipher.decrypt(encrypted_success_buf[0..n_read]);

    var success_fbs = std.io.fixedBufferStream(encrypted_success_buf[0..n_read]);
    const success_r = success_fbs.reader();
    _ = try types.readVarInt(success_r); // packet length
    const success_pkt_id = try types.readVarInt(success_r);
    try std.testing.expectEqual(@as(i32, 0x02), success_pkt_id);

    var success_uuid: [16]u8 = undefined;
    try success_r.readNoEof(&success_uuid);
    const success_name = try types.readString(success_r, allocator, 64);
    defer allocator.free(success_name);

    try std.testing.expectEqualStrings("Steve", success_name);
    // Проверяем, что UUID совпадает с полученным от Mojang: 069a79f444e94726a5bef2a2fce1b293
    var expected_uuid: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_uuid, "069a79f444e94726a5bef2a2fce1b293");
    try std.testing.expectEqual(expected_uuid, success_uuid);

    // 10. Клиент отправляет Login Acknowledged (0x03)
    const ack_pkt = packet.Packet{ .id = 0x03, .payload = &[_]u8{} };
    try handleLogin(&c, &ack_pkt);
    try std.testing.expectEqual(server.ConnectionState.configuration, c.state);
}

test "Валидация имени игрока: отклонение пустых и некорректных ников" {
    const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    var c = server.Client.init(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator);
    c.state = .login;
    defer c.arena.deinit();

    // 1. Пустое имя "" -> должно отклоняться
    var fbs_buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&fbs_buf);
    try types.writeString(fbs.writer(), ""); // длина 0
    try fbs.writer().writeAll(&std.mem.zeroes([16]u8));

    const pkt_empty = packet.Packet{ .id = 0x00, .payload = fbs.getWritten() };
    try handleLogin(&c, &pkt_empty);
    try std.testing.expectEqual(server.ConnectionState.disconnected, c.state);

    // 2. Имя с недопустимыми спецсимволами "User@Name!"
    c.state = .login;
    fbs.reset();
    try types.writeString(fbs.writer(), "User@Name!");
    try fbs.writer().writeAll(&std.mem.zeroes([16]u8));

    const pkt_invalid = packet.Packet{ .id = 0x00, .payload = fbs.getWritten() };
    try handleLogin(&c, &pkt_invalid);
    try std.testing.expectEqual(server.ConnectionState.disconnected, c.state);
}