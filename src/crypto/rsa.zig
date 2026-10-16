const std = @import("std");

pub const RsaKeyPair = struct {
    allocator: std.mem.Allocator,
    priv_key_path: []const u8,
    public_key_der: []const u8,

    pub fn deinit(self: *RsaKeyPair) void {
        self.allocator.free(self.priv_key_path);
        self.allocator.free(self.public_key_der);
    }

    /// Дешифрование RSA-2048 PKCS#1 v1.5 с использованием локального приватного ключа
    pub fn decrypt(self: *const RsaKeyPair, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        var child = std.process.Child.init(&[_][]const u8{
            "openssl",
            "pkeyutl",
            "-decrypt",
            "-inkey",
            self.priv_key_path,
            "-pkeyopt",
            "rsa_padding_mode:pkcs1",
        }, allocator);

        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |*stdin| {
            try stdin.writeAll(ciphertext);
            stdin.close();
            child.stdin = null;
        }

        const out = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        errdefer allocator.free(out);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    allocator.free(out);
                    return error.DecryptionFailed;
                }
            },
            else => {
                allocator.free(out);
                return error.DecryptionFailed;
            },
        }

        return out;
    }
};

/// Вспомогательная функция шифрования открытым DER-ключом (для клиентских тестов)
pub fn encryptWithPubDer(allocator: std.mem.Allocator, pub_der: []const u8, message: []const u8) ![]u8 {
    const tmp_path = "tmp_client_pub.der";
    const f = try std.fs.cwd().createFile(tmp_path, .{});
    try f.writeAll(pub_der);
    f.close();
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var child = std.process.Child.init(&[_][]const u8{
        "openssl",
        "pkeyutl",
        "-encrypt",
        "-pubin",
        "-keyform",
        "DER",
        "-inkey",
        tmp_path,
        "-pkeyopt",
        "rsa_padding_mode:pkcs1",
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    try child.stdin.?.writeAll(message);
    child.stdin.?.close();
    child.stdin = null;

    const out = try child.stdout.?.readToEndAlloc(allocator, 1024);
    errdefer allocator.free(out);
    _ = try child.wait();
    return out;
}

/// Генерация при первом старте или загрузка ключей RSA-2048 с правами 0600
pub fn initOrLoadRsaKeys(allocator: std.mem.Allocator, priv_path_in: []const u8, pub_path_in: []const u8) !RsaKeyPair {
    const cwd = std.fs.cwd();

    const priv_path = if (priv_path_in.len == 0) "server_rsa.priv" else priv_path_in;
    const pub_path = if (pub_path_in.len == 0) "server_rsa.der" else pub_path_in;

    const priv_exists = blk: {
        const f = cwd.openFile(priv_path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };
    const pub_exists = blk: {
        const f = cwd.openFile(pub_path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    if (!priv_exists or !pub_exists) {
        std.debug.print("[ШИФРОВАНИЕ] Генерация новой ключевой пары RSA-2048 с правами 0600...\n", .{});

        // 1. Создаем приватный ключ с правами доступа 0600 (только для владельца)
        const dummy_priv = try cwd.createFile(priv_path, .{ .mode = 0o600 });
        dummy_priv.close();

        var gen_child = std.process.Child.init(&[_][]const u8{
            "openssl",
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:2048",
            "-out",
            priv_path,
        }, allocator);
        gen_child.stderr_behavior = .Ignore;
        gen_child.stdout_behavior = .Ignore;
        try gen_child.spawn();
        _ = try gen_child.wait();

        // Убеждаемся, что права строго 0600
        const fd = try std.posix.open(priv_path, .{ .ACCMODE = .RDWR }, 0);
        defer std.posix.close(fd);
        try std.posix.fchmod(fd, 0o600);

        // 2. Экспортируем публичный ключ в DER (SubjectPublicKeyInfo)
        var pub_child = std.process.Child.init(&[_][]const u8{
            "openssl",
            "rsa",
            "-in",
            priv_path,
            "-pubout",
            "-outform",
            "DER",
            "-out",
            pub_path,
        }, allocator);
        pub_child.stderr_behavior = .Ignore;
        pub_child.stdout_behavior = .Ignore;
        try pub_child.spawn();
        _ = try pub_child.wait();

        std.debug.print("[ШИФРОВАНИЕ] Ключи RSA-2048 сгенерированы: '{s}' (права 0600), '{s}'.\n", .{ priv_path, pub_path });
    }

    const pub_file = try cwd.openFile(pub_path, .{});
    defer pub_file.close();
    const pub_der = try pub_file.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(pub_der);

    const owned_priv_path = try allocator.dupe(u8, priv_path);
    errdefer allocator.free(owned_priv_path);

    return RsaKeyPair{
        .allocator = allocator,
        .priv_key_path = owned_priv_path,
        .public_key_der = pub_der,
    };
}

test "RSA-2048 генерация с правами 0600 и проверка расшифровки PKCS#1 v1.5" {
    const allocator = std.testing.allocator;
    const test_priv = "test_rsa_priv_tmp.priv";
    const test_pub = "test_rsa_pub_tmp.der";
    const test_pub_pem = "test_rsa_pub_tmp.pem";
    defer {
        std.fs.cwd().deleteFile(test_priv) catch {};
        std.fs.cwd().deleteFile(test_pub) catch {};
        std.fs.cwd().deleteFile(test_pub_pem) catch {};
    }

    var keys = try initOrLoadRsaKeys(allocator, test_priv, test_pub);
    defer keys.deinit();

    // Проверяем права 0600 на приватном ключе
    const stat = try std.fs.cwd().statFile(test_priv);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @truncate(stat.mode & 0o777)));
    try std.testing.expectEqual(@as(usize, 294), keys.public_key_der.len);

    // Экспортируем pubkey в PEM для тестового шифрования
    var pub_pem_child = std.process.Child.init(&[_][]const u8{
        "openssl",
        "rsa",
        "-in",
        test_priv,
        "-pubout",
        "-out",
        test_pub_pem,
    }, allocator);
    pub_pem_child.stderr_behavior = .Ignore;
    pub_pem_child.stdout_behavior = .Ignore;
    try pub_pem_child.spawn();
    _ = try pub_pem_child.wait();

    // Зашифруем 16 байт через openssl
    const secret = "0123456789abcdef";
    var enc_child = std.process.Child.init(&[_][]const u8{
        "openssl",
        "pkeyutl",
        "-encrypt",
        "-pubin",
        "-inkey",
        test_pub_pem,
        "-pkeyopt",
        "rsa_padding_mode:pkcs1",
    }, allocator);
    enc_child.stdin_behavior = .Pipe;
    enc_child.stdout_behavior = .Pipe;
    enc_child.stderr_behavior = .Ignore;
    try enc_child.spawn();

    try enc_child.stdin.?.writeAll(secret);
    enc_child.stdin.?.close();
    enc_child.stdin = null;

    const ciphertext = try enc_child.stdout.?.readToEndAlloc(allocator, 1024);
    defer allocator.free(ciphertext);
    _ = try enc_child.wait();

    try std.testing.expectEqual(@as(usize, 256), ciphertext.len);

    // Проверяем дешифрование через keys.decrypt
    const decrypted = try keys.decrypt(allocator, ciphertext);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings(secret, decrypted);
}
