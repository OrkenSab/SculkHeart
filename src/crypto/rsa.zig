const std = @import("std");

pub const RsaKeyPair = struct {
    allocator: std.mem.Allocator,
    public_key_der: []const u8,
    modulus: [256]u8,
    private_exp: [256]u8,

    pub fn deinit(self: *RsaKeyPair) void {
        self.allocator.free(self.public_key_der);
    }

    /// Чистое нативное дешифрование RSA-2048 PKCS#1 v1.5 в памяти процесса (0 дочерних процессов)
    pub fn decrypt(self: *const RsaKeyPair, allocator: std.mem.Allocator, ciphertext: []const u8) ![]u8 {
        if (ciphertext.len != 256) {
            return error.InvalidCiphertextLength;
        }

        var n_num = try std.math.big.int.Managed.init(allocator);
        defer n_num.deinit();
        try setBigEndianBytes(&n_num, &self.modulus);

        var d_num = try std.math.big.int.Managed.init(allocator);
        defer d_num.deinit();
        try setBigEndianBytes(&d_num, &self.private_exp);

        var ct_num = try std.math.big.int.Managed.init(allocator);
        defer ct_num.deinit();
        try setBigEndianBytes(&ct_num, ciphertext);

        var pt_num = try std.math.big.int.Managed.init(allocator);
        defer pt_num.deinit();

        try modPow(&pt_num, &ct_num, &d_num, &n_num, allocator);

        var decrypted_block: [256]u8 = undefined;
        try toBigEndianBytes(&pt_num, &decrypted_block, allocator);

        // Проверка структуры PKCS#1 v1.5: 0x00 0x02 [PS >= 8 байт не-ноль] 0x00 [сообщение]
        if (decrypted_block[0] != 0x00 or decrypted_block[1] != 0x02) {
            return error.InvalidPadding;
        }

        var sep: usize = 2;
        while (sep < 256 and decrypted_block[sep] != 0) : (sep += 1) {}
        if (sep < 10 or sep >= 255) {
            return error.InvalidPadding;
        }

        const payload = decrypted_block[sep + 1 ..];
        return try allocator.dupe(u8, payload);
    }

    /// Чистое нативное шифрование открытым ключом RSA-2048 PKCS#1 v1.5 (e=65537) с криптографическим рандомом в PS
    pub fn encryptPkcs1v15(self: *const RsaKeyPair, allocator: std.mem.Allocator, message: []const u8) ![256]u8 {
        if (message.len > 256 - 11) return error.MessageTooLong;

        var block: [256]u8 = undefined;
        block[0] = 0x00;
        block[1] = 0x02;
        const ps_len = 256 - 3 - message.len;

        // По стандарту RFC 2313 (PKCS#1 v1.5 type 2) padding bytes PS обязаны быть псевдослучайными и ненулевыми
        for (block[2 .. 2 + ps_len]) |*b| {
            var r: u8 = 0;
            while (r == 0) {
                r = std.crypto.random.int(u8);
            }
            b.* = r;
        }
        block[2 + ps_len] = 0x00;
        @memcpy(block[3 + ps_len ..], message);

        var base = try std.math.big.int.Managed.init(allocator);
        defer base.deinit();
        try setBigEndianBytes(&base, &block);

        var exp = try std.math.big.int.Managed.initSet(allocator, 65537);
        defer exp.deinit();

        var mod = try std.math.big.int.Managed.init(allocator);
        defer mod.deinit();
        try setBigEndianBytes(&mod, &self.modulus);

        var res = try std.math.big.int.Managed.init(allocator);
        defer res.deinit();

        try modPow(&res, &base, &exp, &mod, allocator);

        var out: [256]u8 = undefined;
        try toBigEndianBytes(&res, &out, allocator);
        return out;
    }
};

fn readAsn1Length(data: []const u8, offset: *usize) !usize {
    if (offset.* >= data.len) return error.InvalidAsn1;
    const b = data[offset.*];
    offset.* += 1;
    if ((b & 0x80) == 0) {
        return b;
    }
    const num_bytes = b & 0x7F;
    if (num_bytes == 0 or num_bytes > 4 or offset.* + num_bytes > data.len) return error.InvalidAsn1;
    var len: usize = 0;
    var i: usize = 0;
    while (i < num_bytes) : (i += 1) {
        len = (len << 8) | data[offset.*];
        offset.* += 1;
    }
    return len;
}

fn readAsn1Integer(data: []const u8, offset: *usize) ![]const u8 {
    if (offset.* >= data.len or data[offset.*] != 0x02) return error.InvalidAsn1;
    offset.* += 1;
    const len = try readAsn1Length(data, offset);
    if (offset.* + len > data.len) return error.InvalidAsn1;
    var slice = data[offset.* .. offset.* + len];
    offset.* += len;

    while (slice.len > 1 and slice[0] == 0x00) {
        slice = slice[1..];
    }
    return slice;
}

/// Корректный разбор ASN.1 DER структуры закрытого ключа (поддержка PKCS#1 и PKCS#8)
fn parseRsaPrivateKey(der: []const u8) !struct { n: []const u8, d: []const u8 } {
    if (der.len < 4 or der[0] != 0x30) return error.InvalidAsn1;
    var offset: usize = 1;
    _ = try readAsn1Length(der, &offset);

    if (offset >= der.len) return error.InvalidAsn1;
    if (der[offset] != 0x02) return error.InvalidAsn1; // INTEGER (version)
    _ = try readAsn1Integer(der, &offset); // version

    if (offset >= der.len) return error.InvalidAsn1;
    if (der[offset] == 0x02) {
        // PKCS#1 RSAPrivateKey: следующий элемент INTEGER (modulus)
        const n = try readAsn1Integer(der, &offset);
        _ = try readAsn1Integer(der, &offset); // e
        const d = try readAsn1Integer(der, &offset);
        return .{ .n = n, .d = d };
    } else if (der[offset] == 0x30) {
        // PKCS#8 PrivateKeyInfo: AlgorithmIdentifier (SEQUENCE)
        offset += 1;
        const alg_len = try readAsn1Length(der, &offset);
        offset += alg_len;

        // OCTET STRING (0x04)
        if (offset >= der.len or der[offset] != 0x04) return error.InvalidAsn1;
        offset += 1;
        _ = try readAsn1Length(der, &offset);

        // Рекурсивно разбираем вложенный PKCS#1 SEQUENCE
        return try parseRsaPrivateKey(der[offset..]);
    } else {
        return error.InvalidAsn1;
    }
}

fn setBigEndianBytes(num: *std.math.big.int.Managed, bytes: []const u8) !void {
    try num.set(0);
    for (bytes) |b| {
        try num.shiftLeft(num, 8);
        try num.addScalar(num, b);
    }
}

fn toBigEndianBytes(num: *const std.math.big.int.Managed, buf: []u8, allocator: std.mem.Allocator) !void {
    var temp = try num.clone();
    defer temp.deinit();
    var q = try std.math.big.int.Managed.init(allocator);
    defer q.deinit();
    var rem = try std.math.big.int.Managed.init(allocator);
    defer rem.deinit();
    var two56 = try std.math.big.int.Managed.initSet(allocator, 256);
    defer two56.deinit();

    var idx = buf.len;
    while (idx > 0) {
        idx -= 1;
        try q.divTrunc(&rem, &temp, &two56);
        buf[idx] = @as(u8, @truncate(try rem.to(usize)));
        try temp.copy(q.toConst());
    }
}

fn modPow(res: *std.math.big.int.Managed, base: *const std.math.big.int.Managed, exp: *const std.math.big.int.Managed, mod: *const std.math.big.int.Managed, allocator: std.mem.Allocator) !void {
    var r = try std.math.big.int.Managed.initSet(allocator, 1);
    defer r.deinit();

    var b = try base.clone();
    defer b.deinit();

    var e = try exp.clone();
    defer e.deinit();

    var temp = try std.math.big.int.Managed.init(allocator);
    defer temp.deinit();
    var q = try std.math.big.int.Managed.init(allocator);
    defer q.deinit();

    const bit_len = e.bitCountAbs();
    var i: usize = 0;
    while (i < bit_len) : (i += 1) {
        if (e.isOdd()) {
            try temp.mul(&r, &b);
            try q.divTrunc(&r, &temp, mod);
        }
        try e.shiftRight(&e, 1);
        if (i + 1 < bit_len) {
            try temp.sqr(&b);
            try q.divTrunc(&b, &temp, mod);
        }
    }

    try res.copy(r.toConst());
}

/// Генерация при первом старте или загрузка ключей RSA-2048 с правами 0600
pub fn initOrLoadRsaKeys(allocator: std.mem.Allocator, priv_path_in: []const u8, pub_path_in: []const u8) !RsaKeyPair {
    const cwd = std.fs.cwd();

    const priv_path = if (priv_path_in.len == 0) "server_rsa.key" else priv_path_in;
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

        const tmp_pem = "tmp_rsa_gen.pem";
        defer cwd.deleteFile(tmp_pem) catch {};

        // 1. Создаем файл приватного ключа строго с правами 0600 (только для владельца)
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
            tmp_pem,
        }, allocator);
        gen_child.stderr_behavior = .Ignore;
        gen_child.stdout_behavior = .Ignore;
        gen_child.spawn() catch |err| {
            cwd.deleteFile(priv_path) catch {};
            std.debug.print("[ШИФРОВАНИЕ] Ошибка запуска openssl genpkey: {any}\n", .{err});
            return err;
        };
        const gen_term = try gen_child.wait();
        if (gen_term != .Exited or gen_term.Exited != 0) {
            cwd.deleteFile(priv_path) catch {};
            return error.KeyGenerationFailed;
        }

        // Конвертируем в традиционный PKCS#1 DER
        var der_child = std.process.Child.init(&[_][]const u8{
            "openssl",
            "rsa",
            "-in",
            tmp_pem,
            "-traditional",
            "-outform",
            "DER",
            "-out",
            priv_path,
        }, allocator);
        der_child.stderr_behavior = .Ignore;
        der_child.stdout_behavior = .Ignore;
        der_child.spawn() catch |err| {
            cwd.deleteFile(priv_path) catch {};
            return err;
        };
        const der_term = try der_child.wait();
        if (der_term != .Exited or der_term.Exited != 0) {
            cwd.deleteFile(priv_path) catch {};
            return error.KeyGenerationFailed;
        }

        // Устанавливаем права 0600
        const fd = try std.posix.open(priv_path, .{ .ACCMODE = .RDWR }, 0);
        defer std.posix.close(fd);
        try std.posix.fchmod(fd, 0o600);

        // 2. Экспортируем публичный ключ в DER (SubjectPublicKeyInfo)
        var pub_child = std.process.Child.init(&[_][]const u8{
            "openssl",
            "rsa",
            "-in",
            tmp_pem,
            "-pubout",
            "-outform",
            "DER",
            "-out",
            pub_path,
        }, allocator);
        pub_child.stderr_behavior = .Ignore;
        pub_child.stdout_behavior = .Ignore;
        pub_child.spawn() catch |err| {
            cwd.deleteFile(priv_path) catch {};
            cwd.deleteFile(pub_path) catch {};
            return err;
        };
        const pub_term = try pub_child.wait();
        if (pub_term != .Exited or pub_term.Exited != 0) {
            cwd.deleteFile(priv_path) catch {};
            cwd.deleteFile(pub_path) catch {};
            return error.KeyGenerationFailed;
        }

        std.debug.print("[ШИФРОВАНИЕ] Ключи RSA-2048 сгенерированы: '{s}' (0600), '{s}'.\n", .{ priv_path, pub_path });
    }

    // Читаем DER закрытого ключа
    const priv_file = try cwd.openFile(priv_path, .{});
    defer priv_file.close();
    var der_buf: [4096]u8 = undefined;
    const der_len = try priv_file.readAll(&der_buf);
    const priv_der = der_buf[0..der_len];

    // Парсим ASN.1 структуру (PKCS#1 или PKCS#8)
    const key_parts = try parseRsaPrivateKey(priv_der);

    if (key_parts.n.len > 256 or key_parts.d.len > 256 or key_parts.n.len < 250 or key_parts.d.len < 250) {
        return error.InvalidKeySize;
    }

    var mod_bytes = [_]u8{0} ** 256;
    @memcpy(mod_bytes[256 - key_parts.n.len ..], key_parts.n);

    var exp_bytes = [_]u8{0} ** 256;
    @memcpy(exp_bytes[256 - key_parts.d.len ..], key_parts.d);
    // Читаем публичный ключ DER
    const pub_file = try cwd.openFile(pub_path, .{});
    defer pub_file.close();
    const pub_der = try pub_file.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(pub_der);

    return RsaKeyPair{
        .allocator = allocator,
        .public_key_der = pub_der,
        .modulus = mod_bytes,
        .private_exp = exp_bytes,
    };
}

test "RSA-2048 чистое нативное дешифрование в памяти процесса (0 subprocesses при decrypt)" {
    const allocator = std.testing.allocator;
    const test_key = "test_key_tmp.key";
    const test_pub = "test_pub_tmp.der";
    defer {
        std.fs.cwd().deleteFile(test_key) catch {};
        std.fs.cwd().deleteFile(test_pub) catch {};
    }

    var keys = try initOrLoadRsaKeys(allocator, test_key, test_pub);
    defer keys.deinit();

    // Проверяем права 0600
    const stat = try std.fs.cwd().statFile(test_key);
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @truncate(stat.mode & 0o777)));
    try std.testing.expectEqual(@as(usize, 294), keys.public_key_der.len);

    // Чистый нативный round-trip без единого процесса
    const secret = "TestInProcessRSA2048";
    const ct = try keys.encryptPkcs1v15(allocator, secret);
    const pt = try keys.decrypt(allocator, &ct);
    defer allocator.free(pt);

    try std.testing.expectEqualStrings(secret, pt);
}
