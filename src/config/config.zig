const std = @import("std");
const toml = @import("toml.zig");

pub const DEFAULT_CONFIG_CONTENT =
    \\# ==============================================================================
    \\# Конфигурационный файл сервера Minecraft 1.21.11 на Zig
    \\# ==============================================================================
    \\
    \\[server]
    \\# Сетевой порт для подключения игроков (по умолчанию 3222)
    \\port = 3222
    \\
    \\# Хост / IP-адрес для прослушивания ("0.0.0.0" для всех интерфейсов)
    \\host = "0.0.0.0"
    \\
    \\# Режим онлайн-авторизации через серверы Mojang (true = лицензия, false = оффлайн)
    \\online_mode = false
    \\
    \\# Максимальное количество игроков онлайн (1..100000)
    \\max_players = 20
    \\
    \\# Описание сервера (MOTD) в списке серверов
    \\motd = "Сервер на Zig 1.21.11 | Плоский мир"
    \\
    \\# URL сервера авторизации сессий Mojang (по умолчанию официальный)
    \\auth_url = "https://sessionserver.mojang.com/session/minecraft/hasJoined"
    \\
    \\# Дальность прорисовки чанков (в чанках, допустимо 2..32)
    \\view_distance = 8
    \\
    \\# Порог сжатия пакетов (-1 = выключено, 256 = стандарт ваниллы)
    \\compression_threshold = -1
    \\
    \\[world]
    \\# Координаты точки спавна игрока
    \\spawn_x = 0.5
    \\spawn_y = -59.0
    \\spawn_z = 0.5
    \\
    \\# Режим игры: "creative", "survival", "adventure", "spectator"
    \\gamemode = "creative"
    \\
;

pub const ServerConfig = struct {
    // [server]
    port: u16 = 3222,
    host: []const u8 = "0.0.0.0",
    online_mode: bool = false,
    max_players: i32 = 20,
    motd: []const u8 = "Сервер на Zig 1.21.11 | Плоский мир",
    view_distance: i32 = 8,
    auth_url: []const u8 = "https://sessionserver.mojang.com/session/minecraft/hasJoined",
    compression_threshold: i32 = -1,

    // [world]
    spawn_x: f64 = 0.5,
    spawn_y: f64 = -59.0,
    spawn_z: f64 = 0.5,
    gamemode: []const u8 = "creative",

    allocator: ?std.mem.Allocator = null,
    owned_host: ?[]const u8 = null,
    owned_motd: ?[]const u8 = null,
    owned_gamemode: ?[]const u8 = null,
    owned_auth_url: ?[]const u8 = null,

    pub fn deinit(self: *ServerConfig) void {
        if (self.allocator) |alloc| {
            if (self.owned_host) |h| alloc.free(h);
            if (self.owned_motd) |m| alloc.free(m);
            if (self.owned_gamemode) |g| alloc.free(g);
            if (self.owned_auth_url) |a| alloc.free(a);
        }
    }

    /// Проверка и безопасная нормализация значений конфигурации
    pub fn validateAndNormalize(self: *ServerConfig) void {
        // 1. Валидация порта
        if (self.port == 0) {
            std.debug.print("[ВАРНИНГ] Недопустимый порт 0 в конфигурации. Сброс на стандартный порт 3222.\n", .{});
            self.port = 3222;
        }

        // 2. Валидация дальности прорисовки (2..32)
        if (self.view_distance < 2 or self.view_distance > 32) {
            std.debug.print("[ВАРНИНГ] Дальность прорисовки {d} вне допустимого диапазона [2..32]. Сброшено на 8.\n", .{self.view_distance});
            self.view_distance = 8;
        }

        // 3. Валидация максимального количества игроков (1..100000)
        if (self.max_players <= 0 or self.max_players > 100_000) {
            std.debug.print("[ВАРНИНГ] Максимальное количество игроков {d} некорректно. Сброшено на 20.\n", .{self.max_players});
            self.max_players = 20;
        }

        // 4. Валидация игрового режима
        const valid_modes = [_][]const u8{ "creative", "survival", "adventure", "spectator" };
        var mode_valid = false;
        for (valid_modes) |vm| {
            if (std.mem.eql(u8, self.gamemode, vm)) {
                mode_valid = true;
                break;
            }
        }
        if (!mode_valid) {
            std.debug.print("[ВАРНИНГ] Неизвестный режим игры '{s}'. Установлен режим 'creative'.\n", .{self.gamemode});
            self.gamemode = "creative";
        }

        // 5. Валидация координаты Y спавна (мир от -64 до 320)
        if (self.spawn_y < -64.0 or self.spawn_y > 320.0) {
            std.debug.print("[ВАРНИНГ] Координата Y спавна {d:.1} вне допустимых границ мира [-64..320]. Сброшено на -59.0.\n", .{self.spawn_y});
            self.spawn_y = -59.0;
        }
    }

    /// Загрузка конфигурации из файла или создание файла с настройками по умолчанию
    pub fn loadOrCreate(allocator: std.mem.Allocator, file_path: []const u8) !ServerConfig {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("[КОНФИГ] Файл '{s}' не найден. Создание файла по умолчанию...\n", .{file_path});
                const create_file = try std.fs.cwd().createFile(file_path, .{});
                defer create_file.close();
                try create_file.writeAll(DEFAULT_CONFIG_CONTENT);
                std.debug.print("[КОНФИГ] Конфигурационный файл '{s}' успешно создан.\n", .{file_path});
                var def_cfg = ServerConfig{};
                def_cfg.validateAndNormalize();
                return def_cfg;
            },
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var doc = try toml.parse(allocator, content);
        defer doc.deinit();

        var cfg = ServerConfig{
            .allocator = allocator,
        };

        // Разбор секции [server]
        if (doc.getSection("server")) |table| {
            var it = table.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (std.mem.eql(u8, k, "port")) {
                    if (entry.value_ptr.asInt(u16)) |p| {
                        cfg.port = p;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.port': ожидалось число. Использован дефолт {d}.\n", .{cfg.port});
                    }
                } else if (std.mem.eql(u8, k, "host")) {
                    if (entry.value_ptr.asString()) |h| {
                        cfg.owned_host = try allocator.dupe(u8, h);
                        cfg.host = cfg.owned_host.?;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.host': ожидалась строка.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "online_mode")) {
                    if (entry.value_ptr.asBool()) |om| {
                        cfg.online_mode = om;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.online_mode': ожидался boolean.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "max_players")) {
                    if (entry.value_ptr.asInt(i32)) |mp| {
                        cfg.max_players = mp;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.max_players': ожидалось число.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "motd")) {
                    if (entry.value_ptr.asString()) |m| {
                        cfg.owned_motd = try allocator.dupe(u8, m);
                        cfg.motd = cfg.owned_motd.?;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.motd': ожидалась строка.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "view_distance")) {
                    if (entry.value_ptr.asInt(i32)) |vd| {
                        cfg.view_distance = vd;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.view_distance': ожидалось число.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "auth_url")) {
                    if (entry.value_ptr.asString()) |a| {
                        cfg.owned_auth_url = try allocator.dupe(u8, a);
                        cfg.auth_url = cfg.owned_auth_url.?;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.auth_url': ожидалась строка.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "compression_threshold")) {
                    if (entry.value_ptr.asInt(i32)) |ct| {
                        cfg.compression_threshold = ct;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'server.compression_threshold': ожидалось число.\n", .{});
                    }
                } else {
                    std.debug.print("[ВАРНИНГ] Неизвестный параметр в секции '[server]': '{s}'.\n", .{k});
                }
            }
        }

        // Разбор секции [world]
        if (doc.getSection("world")) |table| {
            var it = table.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (std.mem.eql(u8, k, "spawn_x")) {
                    if (entry.value_ptr.asFloat(f64)) |sx| {
                        cfg.spawn_x = sx;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'world.spawn_x': ожидалось число.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "spawn_y")) {
                    if (entry.value_ptr.asFloat(f64)) |sy| {
                        cfg.spawn_y = sy;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'world.spawn_y': ожидалось число.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "spawn_z")) {
                    if (entry.value_ptr.asFloat(f64)) |sz| {
                        cfg.spawn_z = sz;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'world.spawn_z': ожидалось число.\n", .{});
                    }
                } else if (std.mem.eql(u8, k, "gamemode")) {
                    if (entry.value_ptr.asString()) |gm| {
                        cfg.owned_gamemode = try allocator.dupe(u8, gm);
                        cfg.gamemode = cfg.owned_gamemode.?;
                    } else {
                        std.debug.print("[ВАРНИНГ] Ошибка типа для 'world.gamemode': ожидалась строка.\n", .{});
                    }
                } else {
                    std.debug.print("[ВАРНИНГ] Неизвестный параметр в секции '[world]': '{s}'.\n", .{k});
                }
            }
        }

        // Проверяем и нормализуем значения
        cfg.validateAndNormalize();

        std.debug.print("[КОНФИГ] Успешно загружен '{s}': порт={d}, online_mode={}, motd='{s}'\n", .{
            file_path,
            cfg.port,
            cfg.online_mode,
            cfg.motd,
        });

        return cfg;
    }
};

test "Создание и загрузка ServerConfig" {
    const allocator = std.testing.allocator;
    const test_path = "test_server_tmp.toml";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // 1. Создание при отсутствии
    var cfg1 = try ServerConfig.loadOrCreate(allocator, test_path);
    defer cfg1.deinit();

    try std.testing.expectEqual(@as(u16, 3222), cfg1.port);
    try std.testing.expectEqual(false, cfg1.online_mode);
    try std.testing.expectEqualStrings("0.0.0.0", cfg1.host);

    // 2. Модификация и повторная загрузка
    const modified_toml =
        \\[server]
        \\port = 25565
        \\host = "127.0.0.1"
        \\online_mode = true
        \\max_players = 100
        \\motd = "Тестовый сервер"
        \\view_distance = 12
        \\compression_threshold = 256
        \\
        \\[world]
        \\spawn_x = 10.0
        \\spawn_y = 64.0
        \\spawn_z = -10.0
        \\gamemode = "survival"
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = modified_toml });

    var cfg2 = try ServerConfig.loadOrCreate(allocator, test_path);
    defer cfg2.deinit();

    try std.testing.expectEqual(@as(u16, 25565), cfg2.port);
    try std.testing.expectEqual(true, cfg2.online_mode);
    try std.testing.expectEqualStrings("127.0.0.1", cfg2.host);
    try std.testing.expectEqual(@as(i32, 100), cfg2.max_players);
    try std.testing.expectEqualStrings("Тестовый сервер", cfg2.motd);
    try std.testing.expectEqual(@as(i32, 12), cfg2.view_distance);
    try std.testing.expectEqual(@as(i32, 256), cfg2.compression_threshold);
    try std.testing.expectEqual(@as(f64, 10.0), cfg2.spawn_x);
    try std.testing.expectEqual(@as(f64, 64.0), cfg2.spawn_y);
    try std.testing.expectEqual(@as(f64, -10.0), cfg2.spawn_z);
    try std.testing.expectEqualStrings("survival", cfg2.gamemode);
}

test "Валидация некорректных значений конфигурации (port=0, view_distance=100500)" {
    const allocator = std.testing.allocator;
    const test_path = "test_server_invalid_tmp.toml";
    defer std.fs.cwd().deleteFile(test_path) catch {};

    const invalid_toml =
        \\[server]
        \\port = 0
        \\view_distance = 100500
        \\max_players = -5
        \\unknown_key = "test"
        \\
        \\[world]
        \\gamemode = "ultra_hardcore_custom"
        \\spawn_y = -999.0
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = test_path, .data = invalid_toml });

    var cfg = try ServerConfig.loadOrCreate(allocator, test_path);
    defer cfg.deinit();

    // Должны сработать безопасные сбросы на дефолты
    try std.testing.expectEqual(@as(u16, 3222), cfg.port);
    try std.testing.expectEqual(@as(i32, 8), cfg.view_distance);
    try std.testing.expectEqual(@as(i32, 20), cfg.max_players);
    try std.testing.expectEqualStrings("creative", cfg.gamemode);
    try std.testing.expectEqual(@as(f64, -59.0), cfg.spawn_y);
}
