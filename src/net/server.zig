const std = @import("std");
const types = @import("../protocol/types.zig");
const packet = @import("../protocol/packet.zig");
pub const server_config_mod = @import("../config/config.zig");
pub const ServerConfig = server_config_mod.ServerConfig;
pub const default_config = ServerConfig{};
pub const crypto = @import("../crypto/crypto.zig");

pub const ConnectionState = enum {
    handshaking,
    status,
    login,
    configuration,
    play,
    disconnected,
};

pub const Client = struct {
    stream: std.net.Stream,
    address: std.net.Address,
    state: ConnectionState,
    protocol_version: i32,
    username: [32]u8,
    username_len: usize,
    uuid: [16]u8,
    teleport_id: i32,
    keep_alive_id: i64,
    last_keep_alive_ack: i64,
    arena: std.heap.ArenaAllocator,
    server_config: *const ServerConfig,
    rsa_keys: ?*const crypto.RsaKeyPair,
    enc_cipher: ?crypto.Cfb8Cipher,
    dec_cipher: ?crypto.Cfb8Cipher,
    verify_token: [4]u8,
    compression_threshold: i32,

    pub fn init(stream: std.net.Stream, address: std.net.Address, base_allocator: std.mem.Allocator) Client {
        return .{
            .stream = stream,
            .address = address,
            .state = .handshaking,
            .protocol_version = 0,
            .username = undefined,
            .username_len = 0,
            .uuid = std.mem.zeroes([16]u8),
            .teleport_id = 0,
            .keep_alive_id = 0,
            .last_keep_alive_ack = 0,
            .arena = std.heap.ArenaAllocator.init(base_allocator),
            .server_config = &default_config,
            .rsa_keys = null,
            .enc_cipher = null,
            .dec_cipher = null,
            .verify_token = [_]u8{0} ** 4,
            .compression_threshold = -1,
        };
    }

    pub const Reader = std.io.Reader(*Client, std.net.Stream.ReadError, read);

    pub fn read(self: *Client, buffer: []u8) std.net.Stream.ReadError!usize {
        const bytes_read = try self.stream.read(buffer);
        if (bytes_read == 0) return 0;
        if (self.dec_cipher) |*c| {
            c.decrypt(buffer[0..bytes_read]);
        }
        return bytes_read;
    }

    pub fn reader(self: *Client) Reader {
        return .{ .context = self };
    }

    pub fn enableEncryption(self: *Client, shared_secret: [16]u8) void {
        self.enc_cipher = crypto.Cfb8Cipher.init(shared_secret);
        self.dec_cipher = crypto.Cfb8Cipher.init(shared_secret);
    }


    pub fn initWithConfig(stream: std.net.Stream, address: std.net.Address, base_allocator: std.mem.Allocator, cfg: *const ServerConfig, rsa: ?*const crypto.RsaKeyPair) Client {
        var client = init(stream, address, base_allocator);
        client.server_config = cfg;
        client.rsa_keys = rsa;
        client.compression_threshold = -1;
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stream.close();
        self.arena.deinit();
    }

    pub fn getUsername(self: *const Client) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn setUsername(self: *Client, name: []const u8) void {
        const copy_len = @min(name.len, self.username.len);
        @memcpy(self.username[0..copy_len], name[0..copy_len]);
        self.username_len = copy_len;
    }

    pub fn sendPacket(self: *Client, pw: *const packet.PacketWriter) !void {
        if (self.enc_cipher) |*c| {
            // 1. Сжатие в промежуточный буфер (если включено): compress(packet)
            var buf = std.ArrayList(u8).init(self.arena.allocator());
            try pw.sendWithCompression(buf.writer(), self.arena.allocator(), self.compression_threshold);
            // 2. Шифрование сжатого буфера: encrypt(compress(packet))
            c.encrypt(buf.items);
            // 3. Отправка в сокет
            try self.stream.writer().writeAll(buf.items);
        } else {
            try pw.sendWithCompression(self.stream.writer(), self.arena.allocator(), self.compression_threshold);
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    net_server: std.net.Server,
    config: ServerConfig,
    running: std.atomic.Value(bool),
    active_clients: std.atomic.Value(i32),
    rsa_keys: ?crypto.RsaKeyPair,

    pub fn init(allocator: std.mem.Allocator, cfg: ServerConfig) !Server {
        const address = try std.net.Address.parseIp4(cfg.host, cfg.port);
        const net_server = try address.listen(.{
            .reuse_address = true,
        });

        var rsa: ?crypto.RsaKeyPair = null;
        if (cfg.online_mode) {
            rsa = try crypto.initOrLoadRsaKeys(allocator, "server_rsa_priv.pem", "server_rsa.der");
        }

        return Server{
            .allocator = allocator,
            .net_server = net_server,
            .config = cfg,
            .running = std.atomic.Value(bool).init(true),
            .active_clients = std.atomic.Value(i32).init(0),
            .rsa_keys = rsa,
        };
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);
        if (self.rsa_keys) |*k| {
            k.deinit();
        }
        self.net_server.deinit();
    }

    pub fn setSocketOptions(fd: std.posix.fd_t) !void {
        // Включение TCP_NODELAY для минимизации сетевых задержек Minecraft
        const one: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(one));

        // Таймаут чтения 30 секунд для предотвращения утечки зависших соединений
        const timeout = std.posix.timeval{ .tv_sec = 30, .tv_usec = 0 };
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
    }
};

test "Инициализация сервера и проверка сетевых опций" {
    var srv = try Server.init(std.testing.allocator, .{ .port = 3299 });
    defer srv.deinit();

    try std.testing.expectEqual(@as(u16, 3299), srv.config.port);
}
