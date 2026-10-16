const std = @import("std");

pub const EncryptCtx = @typeInfo(@TypeOf(std.crypto.core.aes.Aes128.initEnc)).Fn.return_type.?;

/// Потоковый симметричный шифр AES-128-CFB8 для сетевого протокола Minecraft
pub const Cfb8Cipher = struct {
    ctx: EncryptCtx,
    iv: [16]u8,

    /// Инициализация шифра. В протоколе Minecraft IV совпадает с общим секретом (shared secret)
    pub fn init(key: [16]u8) Cfb8Cipher {
        return .{
            .ctx = std.crypto.core.aes.Aes128.initEnc(key),
            .iv = key,
        };
    }

    /// Инициализация с явным IV
    pub fn initWithIv(key: [16]u8, iv: [16]u8) Cfb8Cipher {
        return .{
            .ctx = std.crypto.core.aes.Aes128.initEnc(key),
            .iv = iv,
        };
    }

    /// Шифрование буфера на месте (in-place)
    pub fn encrypt(self: *Cfb8Cipher, buf: []u8) void {
        for (buf) |*b| {
            var block: [16]u8 = undefined;
            self.ctx.encrypt(&block, &self.iv);
            const out_b = b.* ^ block[0];
            std.mem.copyForwards(u8, self.iv[0..15], self.iv[1..16]);
            self.iv[15] = out_b;
            b.* = out_b;
        }
    }

    /// Дешифрование буфера на месте (in-place)
    pub fn decrypt(self: *Cfb8Cipher, buf: []u8) void {
        for (buf) |*b| {
            var block: [16]u8 = undefined;
            self.ctx.encrypt(&block, &self.iv);
            const in_b = b.*;
            const plain_b = in_b ^ block[0];
            std.mem.copyForwards(u8, self.iv[0..15], self.iv[1..16]);
            self.iv[15] = in_b;
            b.* = plain_b;
        }
    }
};

test "AES-128-CFB8 симметричность шифрования и дешифрования" {
    const key = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var enc = Cfb8Cipher.init(key);
    var dec = Cfb8Cipher.init(key);

    const original_text = "Тестовое сообщение протокола Minecraft 1.21.11! Проверка потока AES CFB8.";
    var buffer: [256]u8 = undefined;
    @memcpy(buffer[0..original_text.len], original_text);

    // Шифруем порциями (как в реальном сетевом потоке)
    enc.encrypt(buffer[0..20]);
    enc.encrypt(buffer[20..original_text.len]);

    // Убеждаемся, что данные зашифрованы
    try std.testing.expect(!std.mem.eql(u8, buffer[0..original_text.len], original_text));

    // Дешифруем другой порцией (например, побайтово)
    for (0..original_text.len) |i| {
        dec.decrypt(buffer[i .. i + 1]);
    }

    // Должен восстановиться исходный текст
    try std.testing.expectEqualStrings(original_text, buffer[0..original_text.len]);
}
