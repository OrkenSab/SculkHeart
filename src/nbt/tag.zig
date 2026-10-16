const std = @import("std");

/// Все 12 типов тегов спецификации NBT (Named Binary Tag)
pub const TagType = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,

    pub fn name(self: TagType) []const u8 {
        return switch (self) {
            .end => "TAG_End",
            .byte => "TAG_Byte",
            .short => "TAG_Short",
            .int => "TAG_Int",
            .long => "TAG_Long",
            .float => "TAG_Float",
            .double => "TAG_Double",
            .byte_array => "TAG_Byte_Array",
            .string => "TAG_String",
            .list => "TAG_List",
            .compound => "TAG_Compound",
            .int_array => "TAG_Int_Array",
            .long_array => "TAG_Long_Array",
        };
    }
};

/// Элемент списка NBT
pub const NbtList = struct {
    elem_type: TagType,
    items: []Tag,
};

/// Структура Compound NBT на базе StringArrayHashMapUnmanaged
pub const NbtCompound = std.StringArrayHashMapUnmanaged(Tag);

/// Универсальный тег NBT (DOM Tree Node)
pub const Tag = union(TagType) {
    end: void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []const u8,
    string: []const u8,
    list: NbtList,
    compound: NbtCompound,
    int_array: []const i32,
    long_array: []const i64,

    /// Создание пустого тега Compound
    pub fn createCompound() Tag {
        return Tag{ .compound = .{} };
    }

    /// Рекурсивное освобождение памяти тега
    pub fn deinit(self: *Tag, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .byte_array => |arr| {
                allocator.free(arr);
            },
            .string => |str| {
                allocator.free(str);
            },
            .int_array => |arr| {
                allocator.free(arr);
            },
            .long_array => |arr| {
                allocator.free(arr);
            },
            .list => |*l| {
                for (l.items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(l.items);
            },
            .compound => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit(allocator);
            },
            else => {},
        }
        self.* = Tag{ .end = {} };
    }

    /// Добавление дочернего тега в составной тег (Compound)
    pub fn put(self: *Tag, allocator: std.mem.Allocator, key: []const u8, tag: Tag) !void {
        switch (self.*) {
            .compound => |*map| {
                const dupe_key = try allocator.dupe(u8, key);
                errdefer allocator.free(dupe_key);

                // Если ключ уже есть, освобождаем старый ключ и значение
                if (map.getEntry(key)) |existing| {
                    allocator.free(dupe_key);
                    var old_val = existing.value_ptr.*;
                    old_val.deinit(allocator);
                    existing.value_ptr.* = tag;
                    return;
                }

                try map.put(allocator, dupe_key, tag);
            },
            else => return error.NotCompound,
        }
    }

    /// Добавление строкового тега
    pub fn putString(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: []const u8) !void {
        const dupe_val = try allocator.dupe(u8, val);
        errdefer allocator.free(dupe_val);
        try self.put(allocator, key, Tag{ .string = dupe_val });
    }

    /// Добавление 32-битного целочисленного тега
    pub fn putInt(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: i32) !void {
        try self.put(allocator, key, Tag{ .int = val });
    }

    /// Добавление байтового тега
    /// Добавление дочернего тега в составной тег с захватом владения уже аллоцированным ключом
    pub fn putOwned(self: *Tag, allocator: std.mem.Allocator, key: []const u8, tag: Tag) !void {
        switch (self.*) {
            .compound => |*map| {
                if (map.getEntry(key)) |existing| {
                    allocator.free(key);
                    var old_val = existing.value_ptr.*;
                    old_val.deinit(allocator);
                    existing.value_ptr.* = tag;
                    return;
                }
                try map.put(allocator, key, tag);
            },
            else => return error.NotCompound,
        }
    }

    pub fn putByte(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: i8) !void {
        try self.put(allocator, key, Tag{ .byte = val });
    }

    /// Добавление 16-битного целочисленного тега
    pub fn putShort(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: i16) !void {
        try self.put(allocator, key, Tag{ .short = val });
    }

    /// Добавление 64-битного целочисленного тега
    pub fn putLong(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: i64) !void {
        try self.put(allocator, key, Tag{ .long = val });
    }

    /// Добавление 32-битного числа с плавающей точкой
    pub fn putFloat(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: f32) !void {
        try self.put(allocator, key, Tag{ .float = val });
    }

    /// Добавление 64-битного числа с плавающей точкой
    pub fn putDouble(self: *Tag, allocator: std.mem.Allocator, key: []const u8, val: f64) !void {
        try self.put(allocator, key, Tag{ .double = val });
    }

    /// Получение дочернего тега по ключу из Compound
    pub fn get(self: *const Tag, key: []const u8) ?Tag {
        return switch (self.*) {
            .compound => |map| map.get(key),
            else => null,
        };
    }

    /// Получение указателя на дочерний тег по ключу
    pub fn getPtr(self: *Tag, key: []const u8) ?*Tag {
        return switch (self.*) {
            .compound => |*map| map.getPtr(key),
            else => null,
        };
    }

    /// Получение целочисленного значения (i32) из Compound
    pub fn getInt(self: *const Tag, key: []const u8) ?i32 {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .int => |v| v,
            .byte => |v| @as(i32, v),
            .short => |v| @as(i32, v),
            else => null,
        };
    }

    /// Получение строки из Compound
    pub fn getString(self: *const Tag, key: []const u8) ?[]const u8 {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    /// Получение байта из Compound
    pub fn getByte(self: *const Tag, key: []const u8) ?i8 {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .byte => |b| b,
            else => null,
        };
    }

    /// Получение 64-битного целого из Compound
    pub fn getLong(self: *const Tag, key: []const u8) ?i64 {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .long => |l| l,
            .int => |i| @as(i64, i),
            else => null,
        };
    }

    /// Получение 64-битного вещественного числа из Compound
    pub fn getDouble(self: *const Tag, key: []const u8) ?f64 {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .double => |d| d,
            .float => |f| @as(f64, f),
            else => null,
        };
    }
};

test "Создание и модификация Compound тега NBT" {
    const allocator = std.testing.allocator;
    var root = Tag.createCompound();
    defer root.deinit(allocator);

    try root.putByte(allocator, "version", 1);
    try root.putInt(allocator, "score", 9999);
    try root.putString(allocator, "name", "Alex");

    try std.testing.expectEqual(@as(?i8, 1), root.getByte("version"));
    try std.testing.expectEqual(@as(?i32, 9999), root.getInt("score"));
    try std.testing.expectEqualStrings("Alex", root.getString("name").?);
    try std.testing.expect(root.get("missing") == null);
}
