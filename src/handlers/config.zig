const std = @import("std");
const types = @import("../protocol/types.zig");
const packet = @import("../protocol/packet.zig");
const server = @import("../net/server.zig");

pub const PACKET_ID_FINISH_CONFIG: i32 = 0x03;
pub const PACKET_ID_REGISTRY_DATA: i32 = 0x07;
pub const PACKET_ID_UPDATE_TAGS: i32 = 0x0D;
pub const PACKET_ID_SELECT_KNOWN_PACKS: i32 = 0x0E;

/// Начало фазы конфигурации: отправка списка известных датапаков (Known Packs)
pub fn startConfiguration(client: *server.Client) !void {
    std.debug.print("[КОНФИГУРАЦИЯ] Начало конфигурации для '{s}', отправка Select Known Packs.\n", .{client.getUsername()});

    var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_SELECT_KNOWN_PACKS);
    // Количество датапаков: 1
    try pw.writeVarInt(1);
    try pw.writeString("minecraft");
    try pw.writeString("core");
    try pw.writeString("1.21.11");

    try client.sendPacket(&pw);
}

/// Отправка синхронизируемых реестров ваниллы с флагом has_data = false
pub fn sendRegistryData(client: *server.Client) !void {
    const registries = [_]struct {
        id: []const u8,
        entries: []const []const u8,
    }{
        .{
            .id = "minecraft:dimension_type",
            .entries = &[_][]const u8{
                "minecraft:overworld",
                "minecraft:overworld_caves",
                "minecraft:the_end",
                "minecraft:the_nether",
            },
        },
        .{
            .id = "minecraft:worldgen/biome",
            .entries = &[_][]const u8{
                "minecraft:plains",
                "minecraft:the_void",
                "minecraft:forest",
                "minecraft:desert",
            },
        },
        .{
            .id = "minecraft:damage_type",
            .entries = &[_][]const u8{
                "minecraft:arrow",
                "minecraft:bad_respawn_point",
                "minecraft:cactus",
                "minecraft:campfire",
                "minecraft:cramming",
                "minecraft:dragon_breath",
                "minecraft:drown",
                "minecraft:dry_out",
                "minecraft:ender_pearl",
                "minecraft:explosion",
                "minecraft:fall",
                "minecraft:falling_anvil",
                "minecraft:falling_block",
                "minecraft:falling_stalactite",
                "minecraft:fireball",
                "minecraft:fireworks",
                "minecraft:fly_into_wall",
                "minecraft:freeze",
                "minecraft:generic",
                "minecraft:generic_kill",
                "minecraft:hot_floor",
                "minecraft:in_fire",
                "minecraft:in_wall",
                "minecraft:indirect_magic",
                "minecraft:lava",
                "minecraft:lightning_bolt",
                "minecraft:mace_smash",
                "minecraft:magic",
                "minecraft:mob_attack",
                "minecraft:mob_attack_no_aggro",
                "minecraft:mob_projectile",
                "minecraft:on_fire",
                "minecraft:out_of_world",
                "minecraft:outside_border",
                "minecraft:player_attack",
                "minecraft:player_explosion",
                "minecraft:sonic_boom",
                "minecraft:spear",
                "minecraft:spit",
                "minecraft:stalagmite",
                "minecraft:starve",
                "minecraft:sting",
                "minecraft:sweet_berry_bush",
                "minecraft:thorns",
                "minecraft:thrown",
                "minecraft:trident",
                "minecraft:unattributed_fireball",
                "minecraft:wind_charge",
                "minecraft:wither",
                "minecraft:wither_skull",
            },
        },
        .{
            .id = "minecraft:painting_variant",
            .entries = &[_][]const u8{
                "minecraft:kebab",
                "minecraft:alban",
                "minecraft:aztec",
                "minecraft:aztec2",
                "minecraft:backyard",
            },
        },
        .{
            .id = "minecraft:banner_pattern",
            .entries = &[_][]const u8{
                "minecraft:base",
                "minecraft:border",
                "minecraft:bricks",
                "minecraft:circle",
                "minecraft:creeper",
                "minecraft:flower",
                "minecraft:globe",
                "minecraft:mojang",
                "minecraft:skull",
            },
        },
        .{
            .id = "minecraft:cat_variant",
            .entries = &[_][]const u8{
                "minecraft:all_black",
                "minecraft:black",
                "minecraft:british_shorthair",
                "minecraft:calico",
                "minecraft:jellie",
                "minecraft:persian",
                "minecraft:ragdoll",
                "minecraft:red",
                "minecraft:siamese",
                "minecraft:tabby",
                "minecraft:white",
            },
        },
        .{
            .id = "minecraft:chicken_variant",
            .entries = &[_][]const u8{
                "minecraft:cold",
                "minecraft:temperate",
                "minecraft:warm",
            },
        },
        .{
            .id = "minecraft:cow_variant",
            .entries = &[_][]const u8{
                "minecraft:cold",
                "minecraft:temperate",
                "minecraft:warm",
            },
        },
        .{
            .id = "minecraft:frog_variant",
            .entries = &[_][]const u8{
                "minecraft:cold",
                "minecraft:temperate",
                "minecraft:warm",
            },
        },
        .{
            .id = "minecraft:pig_variant",
            .entries = &[_][]const u8{
                "minecraft:cold",
                "minecraft:temperate",
                "minecraft:warm",
            },
        },
        .{
            .id = "minecraft:wolf_sound_variant",
            .entries = &[_][]const u8{
                "minecraft:angry",
                "minecraft:big",
                "minecraft:classic",
                "minecraft:cute",
                "minecraft:grumpy",
                "minecraft:puglin",
                "minecraft:sad",
            },
        },
        .{
            .id = "minecraft:wolf_variant",
            .entries = &[_][]const u8{
                "minecraft:ashen",
                "minecraft:black",
                "minecraft:chestnut",
                "minecraft:pale",
                "minecraft:rusty",
                "minecraft:snowy",
                "minecraft:spotted",
                "minecraft:striped",
                "minecraft:woods",
            },
        },
        .{
            .id = "minecraft:zombie_nautilus_variant",
            .entries = &[_][]const u8{
                "minecraft:temperate",
                "minecraft:warm",
            },
        },
        .{
            .id = "minecraft:timeline",
            .entries = &[_][]const u8{
                "minecraft:day",
                "minecraft:early_game",
                "minecraft:moon",
                "minecraft:villager_schedule",
            },
        },
        .{
            .id = "minecraft:chat_type",
            .entries = &[_][]const u8{
                "minecraft:chat",
                "minecraft:emote_command",
                "minecraft:msg_command_incoming",
                "minecraft:msg_command_outgoing",
                "minecraft:say_command",
            },
        },
        .{
            .id = "minecraft:trim_material",
            .entries = &[_][]const u8{
                "minecraft:amethyst",
                "minecraft:copper",
                "minecraft:diamond",
                "minecraft:emerald",
                "minecraft:gold",
                "minecraft:iron",
                "minecraft:lapis",
                "minecraft:netherite",
                "minecraft:quartz",
                "minecraft:redstone",
                "minecraft:resin",
            },
        },
        .{
            .id = "minecraft:trim_pattern",
            .entries = &[_][]const u8{
                "minecraft:bolt",
                "minecraft:coast",
                "minecraft:dune",
                "minecraft:eye",
                "minecraft:flow",
                "minecraft:host",
                "minecraft:raiser",
                "minecraft:rib",
                "minecraft:sentry",
                "minecraft:shaper",
                "minecraft:silence",
                "minecraft:snout",
                "minecraft:spire",
                "minecraft:tide",
                "minecraft:vex",
                "minecraft:ward",
                "minecraft:wayfinder",
                "minecraft:wild",
            },
        },
        .{
            .id = "minecraft:instrument",
            .entries = &[_][]const u8{
                "minecraft:admire_goat_horn",
                "minecraft:call_goat_horn",
                "minecraft:dream_goat_horn",
                "minecraft:feel_goat_horn",
                "minecraft:ponder_goat_horn",
                "minecraft:seek_goat_horn",
                "minecraft:sing_goat_horn",
                "minecraft:yearn_goat_horn",
            },
        },
        .{
            .id = "minecraft:jukebox_song",
            .entries = &[_][]const u8{
                "minecraft:11",
                "minecraft:13",
                "minecraft:5",
                "minecraft:blocks",
                "minecraft:cat",
                "minecraft:chirp",
                "minecraft:far",
                "minecraft:mall",
                "minecraft:mellohi",
                "minecraft:otherside",
                "minecraft:pigstep",
                "minecraft:precipice",
                "minecraft:relic",
                "minecraft:stal",
                "minecraft:strad",
                "minecraft:wait",
                "minecraft:ward",
            },
        },
    };

    for (registries) |reg| {
        var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_REGISTRY_DATA);
        try pw.writeString(reg.id);
        try pw.writeVarInt(@as(i32, @intCast(reg.entries.len)));

        for (reg.entries) |entry| {
            try pw.writeString(entry);
            // has_data = false (0x00), клиент использует встроенные данные ванильного датапака
            try pw.writeU8(0);
        }

        try client.sendPacket(&pw);
    }
}

/// Отправка тегов (Update Tags)
pub fn sendTags(client: *server.Client) !void {
    var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_UPDATE_TAGS);

    // Количество реестров тегов: 2
    try pw.writeVarInt(2);

    // 1. minecraft:damage_type
    try pw.writeString("minecraft:damage_type");
    try pw.writeVarInt(1); // 1 тег
    try pw.writeString("minecraft:bypasses_shield");
    try pw.writeVarInt(0); // 0 элементов

    // 2. minecraft:timeline
    try pw.writeString("minecraft:timeline");
    try pw.writeVarInt(4); // 4 тега

    // minecraft:universal -> [3] (villager_schedule)
    try pw.writeString("minecraft:universal");
    try pw.writeVarInt(1);
    try pw.writeVarInt(3);

    // minecraft:in_overworld -> [0, 1, 2, 3]
    try pw.writeString("minecraft:in_overworld");
    try pw.writeVarInt(4);
    try pw.writeVarInt(0);
    try pw.writeVarInt(1);
    try pw.writeVarInt(2);
    try pw.writeVarInt(3);

    // minecraft:in_nether -> [3]
    try pw.writeString("minecraft:in_nether");
    try pw.writeVarInt(1);
    try pw.writeVarInt(3);

    // minecraft:in_end -> [3]
    try pw.writeString("minecraft:in_end");
    try pw.writeVarInt(1);
    try pw.writeVarInt(3);

    try client.sendPacket(&pw);
}

/// Отправка пакета завершения конфигурации (Finish Configuration)
pub fn sendFinishConfiguration(client: *server.Client) !void {
    var pw = packet.PacketWriter.init(client.arena.allocator(), PACKET_ID_FINISH_CONFIG);
    try client.sendPacket(&pw);
}

/// Обработка входящих пакетов фазы Configuration
pub fn handleConfiguration(client: *server.Client, pkt: *const packet.Packet) !void {
    switch (pkt.id) {
        0x00 => {
            // Client Information (настройки клиента: язык, дальность прорисовки)
            std.debug.print("[КОНФИГУРАЦИЯ] Получены настройки клиента от '{s}'.\n", .{client.getUsername()});
        },
        0x01, 0x02 => {
            // Plugin Message / Custom Payload (бренд клиента и т.д.)
            std.debug.print("[КОНФИГУРАЦИЯ] Получен плагин-пакет от '{s}'.\n", .{client.getUsername()});
        },
        0x07 => {
            // Select Known Packs (ответ клиента со списком известных ему датапаков)
            std.debug.print("[КОНФИГУРАЦИЯ] Клиент '{s}' подтвердил известные датапаки.\n", .{client.getUsername()});

            // Отправляем данные реестров
            try sendRegistryData(client);
            // Отправляем теги
            try sendTags(client);
            // Отправляем Finish Configuration
            try sendFinishConfiguration(client);
            std.debug.print("[КОНФИГУРАЦИЯ] Отправлен Finish Configuration игроку '{s}'.\n", .{client.getUsername()});
        },
        PACKET_ID_FINISH_CONFIG => {
            // Acknowledge Finish Configuration (0x03)
            std.debug.print("[КОНФИГУРАЦИЯ] Игрок '{s}' подтвердил завершение конфигурации, переход в Play!\n", .{client.getUsername()});
            client.state = .play;
        },
        else => {
            std.debug.print("[КОНФИГУРАЦИЯ] Пакет 0x{X:0>2} от '{s}'.\n", .{ pkt.id, client.getUsername() });
        },
    }
}

// =================== Тесты фазы Configuration ===================

test "Проверка формирования пакетов конфигурации" {
    const dummy_addr = try std.net.Address.parseIp4("127.0.0.1", 3222);
    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    var c = server.Client.init(.{ .handle = pipe_fds[1] }, dummy_addr, std.testing.allocator);
    defer c.arena.deinit();
    c.setUsername("Tester");

    try startConfiguration(&c);
    try sendRegistryData(&c);
    try sendTags(&c);
    try sendFinishConfiguration(&c);

    // Проверяем смену состояния по подтверждению
    const finish_ack = packet.Packet{ .id = 0x03, .payload = &[_]u8{} };
    try handleConfiguration(&c, &finish_ack);
    try std.testing.expectEqual(server.ConnectionState.play, c.state);
}
