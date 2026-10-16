const std = @import("std");

/// Буфер для хранения строки Minecraft SHA-1 хэша со знаком (максимум: '-' + 40 hex символов)
pub const McHashString = struct {
    buf: [41]u8,
    len: usize,

    pub fn slice(self: *const McHashString) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Преобразование 20-байтового SHA-1 дайджеста в Minecraft знаковый hex-формат
pub fn formatMinecraftDigest(digest: [20]u8) McHashString {
    var result = McHashString{
        .buf = undefined,
        .len = 0,
    };

    const is_negative = (digest[0] & 0x80) != 0;
    var magnitude: [20]u8 = undefined;

    if (is_negative) {
        // Отрицательное число в дополнительном коде (two's complement): инвертируем биты и прибавляем 1
        for (digest, 0..) |b, i| {
            magnitude[i] = ~b;
        }
        var carry: u16 = 1;
        var i: usize = 20;
        while (i > 0) {
            i -= 1;
            const sum = @as(u16, magnitude[i]) + carry;
            magnitude[i] = @as(u8, @truncate(sum));
            carry = sum >> 8;
        }
    } else {
        @memcpy(&magnitude, &digest);
    }

    // Поиск первого ненулевого байта для удаления лидирующих нулей
    var idx: usize = 0;
    while (idx < 20 and magnitude[idx] == 0) : (idx += 1) {}

    if (idx == 20) {
        result.buf[0] = '0';
        result.len = 1;
        return result;
    }

    var out_pos: usize = 0;
    if (is_negative) {
        result.buf[out_pos] = '-';
        out_pos += 1;
    }

    const hex_chars = "0123456789abcdef";

    // Первый значащий байт (если старший полубайт 0, выводим только один символ)
    const first_byte = magnitude[idx];
    const high_nibble = (first_byte >> 4) & 0x0F;
    const low_nibble = first_byte & 0x0F;

    if (high_nibble != 0) {
        result.buf[out_pos] = hex_chars[high_nibble];
        out_pos += 1;
    }
    result.buf[out_pos] = hex_chars[low_nibble];
    out_pos += 1;
    idx += 1;

    // Все последующие байты форматируются ровно по 2 hex-символа
    while (idx < 20) : (idx += 1) {
        const b = magnitude[idx];
        result.buf[out_pos] = hex_chars[(b >> 4) & 0x0F];
        out_pos += 1;
        result.buf[out_pos] = hex_chars[b & 0x0F];
        out_pos += 1;
    }

    result.len = out_pos;
    return result;
}

/// Вычисление Minecraft хэша: Sha1(server_id + shared_secret + public_key_der)
pub fn computeMinecraftHash(server_id: []const u8, shared_secret: []const u8, public_key_der: []const u8) McHashString {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(server_id);
    sha.update(shared_secret);
    sha.update(public_key_der);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return formatMinecraftDigest(digest);
}

test "Minecraft SHA-1 вычисление хэша по тестовым векторам Minecraft Wiki" {
    // Вектор 1: "Notch"
    {
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update("Notch");
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        const res = formatMinecraftDigest(digest);
        try std.testing.expectEqualStrings("4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48", res.slice());
    }

    // Вектор 2: "jeb_"
    {
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update("jeb_");
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        const res = formatMinecraftDigest(digest);
        try std.testing.expectEqualStrings("-7c9d5b0044c130109a5d7b5fb5c317c02b4e28c1", res.slice());
    }

    // Вектор 3: "simon"
    {
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update("simon");
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        const res = formatMinecraftDigest(digest);
        try std.testing.expectEqualStrings("88e16a1019277b15d58faf0541e11910eb756f6", res.slice());
    }

    // Вектор 4: ""
    {
        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update("");
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        const res = formatMinecraftDigest(digest);
        try std.testing.expectEqualStrings("-25c65c11a194b4f2cdaa40106a9fe76f5027f8f7", res.slice());
    }
}
