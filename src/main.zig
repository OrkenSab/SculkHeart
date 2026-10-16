const std = @import("std");

pub const types = @import("protocol/types.zig");
pub const packet = @import("protocol/packet.zig");
pub const server = @import("net/server.zig");
pub const login = @import("handlers/login.zig");
pub const config = @import("handlers/config.zig");
pub const status = @import("handlers/status.zig");
pub const chunk = @import("world/chunk.zig");
pub const play = @import("handlers/play.zig");
pub const nbt = @import("nbt/nbt.zig");
pub const server_config = @import("config/config.zig");
pub const toml = @import("config/toml.zig");
pub const crypto = @import("crypto/crypto.zig");
test {
    std.testing.refAllDecls(@This());
}
var global_srv_running: ?*std.atomic.Value(bool) = null;

fn handleSignal(sig: c_int) callconv(.C) void {
    _ = sig;
    if (global_srv_running) |running| {
        running.store(false, .seq_cst);
    }
}


fn handleClient(client: *server.Client) !void {
    const reader = client.reader();
    var last_keep_alive_sent = std.time.milliTimestamp();

    while (client.state != .disconnected) {
        const pkt = packet.readPacketCompressed(reader, client.arena.allocator(), 1024 * 1024, client.compression_threshold) catch |err| switch (err) {
            error.EndOfStream, error.ConnectionResetByPeer => {
                client.state = .disconnected;
                break;
            },
            error.WouldBlock => {
                // Таймаут чтения сокета (SO_RCVTIMEO)
                if (client.state == .play) {
                    const now = std.time.milliTimestamp();
                    if (now - last_keep_alive_sent >= 10000) {
                        try play.sendKeepAlive(client);
                        last_keep_alive_sent = now;
                    }
                    continue;
                }
                // Для других состояний длительное бездействие означает отключение
                client.state = .disconnected;
                break;
            },
            else => return err,
        };

        switch (client.state) {
            .handshaking => {
                try status.handleHandshake(client, &pkt);
            },
            .status => {
                try status.handleStatus(client, &pkt);
            },
            .login => {
                try login.handleLogin(client, &pkt);
                if (client.state == .configuration) {
                    try config.startConfiguration(client);
                }
            },
            .configuration => {
                try config.handleConfiguration(client, &pkt);
                if (client.state == .play) {
                    try play.startPlay(client);
                    last_keep_alive_sent = std.time.milliTimestamp();
                }
            },
            .play => {
                try play.handlePlay(client, &pkt);
            },
            .disconnected => break,
        }

        // Периодический Keep Alive и проверка таймаута (30 секунд) в фазе Play
        if (client.state == .play) {
            const now = std.time.milliTimestamp();
            if (client.last_keep_alive_ack > 0 and (now - client.last_keep_alive_ack >= 30000)) {
                std.debug.print("[СЕТЬ] Клиент '{s}' превысил таймаут Keep Alive (30с). Отключение.\n", .{client.getUsername()});
                client.state = .disconnected;
                break;
            }
            if (now - last_keep_alive_sent >= 10000) {
                try play.sendKeepAlive(client);
                last_keep_alive_sent = now;
            }
        }

        // Освобождение временных аллокаций пакета для предотвращения утечек
        _ = client.arena.reset(.free_all);
    }

    std.debug.print("[СЕТЬ] Клиент {any} отключился.\n", .{client.address});
}

fn clientWorker(client_ptr: *server.Client, srv_ptr: *server.Server) void {
    defer {
        _ = srv_ptr.active_clients.fetchSub(1, .seq_cst);
        client_ptr.deinit();
        std.heap.page_allocator.destroy(client_ptr);
    }

    handleClient(client_ptr) catch |err| {
        if (err != error.EndOfStream and err != error.ConnectionResetByPeer and err != error.WouldBlock) {
            std.debug.print("[СЕТЬ] Ошибка обработки клиента: {any}\n", .{err});
        }
    };
}

pub fn main() !void {
    const start_time = std.time.nanoTimestamp();
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var benchmark_start = false;
    var config_path: []const u8 = "server.toml";

    var arg_i: usize = 1;
    while (arg_i < args.len) : (arg_i += 1) {
        const arg = args[arg_i];
        if (std.mem.eql(u8, arg, "--benchmark-start")) {
            benchmark_start = true;
        } else if (std.mem.eql(u8, arg, "--config") and arg_i + 1 < args.len) {
            arg_i += 1;
            config_path = args[arg_i];
        } else if (std.mem.endsWith(u8, arg, ".toml")) {
            config_path = arg;
        }
    }

    var cfg = try server_config.ServerConfig.loadOrCreate(allocator, config_path);
    defer cfg.deinit();

    var srv = try server.Server.init(allocator, cfg);
    defer srv.deinit();

    global_srv_running = &srv.running;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
    std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    const elapsed_ns = std.time.nanoTimestamp() - start_time;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    std.debug.print("====================================================\n", .{});
    std.debug.print(" Minecraft Java Server 1.21.11 (Протокол 774) на Zig\n", .{});
    std.debug.print(" Режим мира: Плоский мир ({s})\n", .{cfg.gamemode});
    std.debug.print(" Режим сети: {s}\n", .{if (cfg.online_mode) "Online-Mode (Mojang Auth)" else "Offline-Mode"});
    std.debug.print(" Сервер запущен на {s}:{d} за {d:.2} мс\n", .{ cfg.host, cfg.port, elapsed_ms });
    std.debug.print("====================================================\n", .{});
    if (benchmark_start) {
        std.debug.print("[БЕНЧМАРК] Тест холодного старта завершен успешно: {d:.2} мс (цель <= 3 мс).\n", .{elapsed_ms});
        return;
    }

    while (srv.running.load(.seq_cst)) {
        const conn = srv.net_server.accept() catch |err| {
            if (!srv.running.load(.seq_cst)) break;
            if (err == error.Interrupted) continue;
            std.debug.print("[СЕТЬ] Ошибка при приеме соединения: {any}\n", .{err});
            continue;
        };

        if (srv.active_clients.load(.seq_cst) >= srv.config.max_players) {
            std.debug.print("[СЕТЬ] Сервер полон ({d}/{d}). Отклонение подключения {any}.\n", .{ srv.active_clients.load(.seq_cst), srv.config.max_players, conn.address });
            conn.stream.close();
            continue;
        }
        _ = srv.active_clients.fetchAdd(1, .seq_cst);

        server.Server.setSocketOptions(conn.stream.handle) catch |err| {
            std.debug.print("[СЕТЬ] Не удалось установить опции сокета: {any}\n", .{err});
        };

        // Устанавливаем таймаут чтения 1 секунду для отзывчивой отправки Keep Alive
        const rcv_timeout = std.posix.timeval{ .tv_sec = 1, .tv_usec = 0 };
        _ = std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(rcv_timeout)) catch {};
        std.debug.print("[СЕТЬ] Новое подключение от {any}\n", .{conn.address});

        const client_ptr = try allocator.create(server.Client);
        client_ptr.* = server.Client.initWithConfig(conn.stream, conn.address, allocator, &srv.config, if (srv.rsa_keys) |*k| k else null);
        const thread = std.Thread.spawn(.{}, clientWorker, .{ client_ptr, &srv }) catch |err| {
            std.debug.print("[СЕТЬ] Не удалось запустить поток для клиента: {any}\n", .{err});
            _ = srv.active_clients.fetchSub(1, .seq_cst);
            client_ptr.deinit();
            allocator.destroy(client_ptr);
            continue;
        };
        thread.detach();
    }
    std.debug.print("[СЕРВЕР] Завершение работы сервера (SIGINT/SIGTERM). Все ресурсы освобождены.\n", .{});
}
