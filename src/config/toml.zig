const std = @import("std");

pub const TomlError = error{
    InvalidSyntax,
    UnexpectedToken,
    UnterminatedString,
    InvalidNumber,
    OutOfMemory,
};

pub const TomlValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []TomlValue,

    pub fn asString(self: TomlValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: TomlValue, comptime T: type) ?T {
        return switch (self) {
            .integer => |i| std.math.cast(T, i),
            else => null,
        };
    }

    pub fn asFloat(self: TomlValue, comptime T: type) ?T {
        return switch (self) {
            .float => |f| @as(T, @floatCast(f)),
            .integer => |i| @as(T, @floatFromInt(i)),
            else => null,
        };
    }

    pub fn asBool(self: TomlValue) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asArray(self: TomlValue) ?[]TomlValue {
        return switch (self) {
            .array => |arr| arr,
            else => null,
        };
    }

    pub fn deinit(self: *TomlValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |*elem| {
                    elem.deinit(allocator);
                }
                allocator.free(arr);
            },
            else => {},
        }
    }
};

pub const TomlTable = std.StringArrayHashMapUnmanaged(TomlValue);

pub const TomlDocument = struct {
    allocator: std.mem.Allocator,
    sections: std.StringArrayHashMapUnmanaged(TomlTable),

    pub fn init(allocator: std.mem.Allocator) TomlDocument {
        return .{
            .allocator = allocator,
            .sections = .{},
        };
    }

    pub fn deinit(self: *TomlDocument) void {
        var sec_it = self.sections.iterator();
        while (sec_it.next()) |sec_entry| {
            self.allocator.free(sec_entry.key_ptr.*);
            var val_it = sec_entry.value_ptr.iterator();
            while (val_it.next()) |val_entry| {
                self.allocator.free(val_entry.key_ptr.*);
                val_entry.value_ptr.deinit(self.allocator);
            }
            sec_entry.value_ptr.deinit(self.allocator);
        }
        self.sections.deinit(self.allocator);
    }

    pub fn getSection(self: *const TomlDocument, section: []const u8) ?*const TomlTable {
        return self.sections.getPtr(section);
    }

    pub fn get(self: *const TomlDocument, section: []const u8, key: []const u8) ?TomlValue {
        const table = self.sections.get(section) orelse return null;
        return table.get(key);
    }

    pub fn getString(self: *const TomlDocument, section: []const u8, key: []const u8) ?[]const u8 {
        const val = self.get(section, key) orelse return null;
        return val.asString();
    }

    pub fn getInt(self: *const TomlDocument, comptime T: type, section: []const u8, key: []const u8) ?T {
        const val = self.get(section, key) orelse return null;
        return val.asInt(T);
    }

    pub fn getFloat(self: *const TomlDocument, comptime T: type, section: []const u8, key: []const u8) ?T {
        const val = self.get(section, key) orelse return null;
        return val.asFloat(T);
    }

    pub fn getBool(self: *const TomlDocument, section: []const u8, key: []const u8) ?bool {
        const val = self.get(section, key) orelse return null;
        return val.asBool();
    }
};

/// Парсинг строки TOML в TomlDocument
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !TomlDocument {
    var doc = TomlDocument.init(allocator);
    errdefer doc.deinit();

    var current_section_name: []const u8 = "";

    var line_it = std.mem.splitScalar(u8, source, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        // Заголовок секции: [section]
        if (line[0] == '[') {
            const end_idx = std.mem.lastIndexOfScalar(u8, line, ']') orelse return TomlError.InvalidSyntax;
            const sec_name = std.mem.trim(u8, line[1..end_idx], " \t");
            if (sec_name.len == 0) return TomlError.InvalidSyntax;

            if (doc.sections.getPtr(sec_name) == null) {
                const dupe_sec = try allocator.dupe(u8, sec_name);
                errdefer allocator.free(dupe_sec);
                try doc.sections.put(allocator, dupe_sec, .{});
            }
            current_section_name = sec_name;
            continue;
        }

        // Ключ = Значение
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key_raw = std.mem.trim(u8, line[0..eq_pos], " \t");
        if (key_raw.len == 0) return TomlError.InvalidSyntax;

        const val_part = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
        var val = try parseValue(allocator, val_part);
        errdefer val.deinit(allocator);

        var table_ptr = doc.sections.getPtr(current_section_name);
        if (table_ptr == null) {
            const dupe_sec = try allocator.dupe(u8, current_section_name);
            errdefer allocator.free(dupe_sec);
            try doc.sections.put(allocator, dupe_sec, .{});
            table_ptr = doc.sections.getPtr(current_section_name);
        }

        if (table_ptr.?.getEntry(key_raw)) |existing| {
            existing.value_ptr.deinit(allocator);
            existing.value_ptr.* = val;
        } else {
            const dupe_key = try allocator.dupe(u8, key_raw);
            errdefer allocator.free(dupe_key);
            try table_ptr.?.put(allocator, dupe_key, val);
        }
    }

    return doc;
}

fn parseValue(allocator: std.mem.Allocator, input: []const u8) TomlError!TomlValue {
    if (input.len == 0) return TomlError.InvalidSyntax;

    // Массив: [ ... ]
    if (input[0] == '[' and input[input.len - 1] == ']') {
        const inner = std.mem.trim(u8, input[1 .. input.len - 1], " \t");
        if (inner.len == 0) {
            const empty = try allocator.alloc(TomlValue, 0);
            return TomlValue{ .array = empty };
        }

        var list = std.ArrayList(TomlValue).init(allocator);
        errdefer {
            for (list.items) |*elem| elem.deinit(allocator);
            list.deinit();
        }

        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |item_raw| {
            const item_str = std.mem.trim(u8, item_raw, " \t\r");
            if (item_str.len == 0) continue;
            const elem = try parseValue(allocator, item_str);
            try list.append(elem);
        }

        return TomlValue{ .array = try list.toOwnedSlice() };
    }

    // Строка в двойных кавычках: "..."
    if (input[0] == '"') {
        var unescaped = std.ArrayList(u8).init(allocator);
        errdefer unescaped.deinit();

        var i: usize = 1;
        var closed = false;
        while (i < input.len) {
            const c = input[i];
            if (c == '"') {
                closed = true;
                break;
            }
            if (c == '\\') {
                i += 1;
                if (i >= input.len) return TomlError.UnterminatedString;
                switch (input[i]) {
                    '"' => try unescaped.append('"'),
                    '\\' => try unescaped.append('\\'),
                    'n' => try unescaped.append('\n'),
                    'r' => try unescaped.append('\r'),
                    't' => try unescaped.append('\t'),
                    else => |esc| try unescaped.append(esc),
                }
            } else {
                try unescaped.append(c);
            }
            i += 1;
        }

        if (!closed) return TomlError.UnterminatedString;
        return TomlValue{ .string = try unescaped.toOwnedSlice() };
    }

    // Отрезаем комментарий в конце значения, если есть
    var clean_val = input;
    if (std.mem.indexOfScalar(u8, clean_val, '#')) |hash_pos| {
        clean_val = std.mem.trim(u8, clean_val[0..hash_pos], " \t");
    }

    // Булевы флаги
    if (std.mem.eql(u8, clean_val, "true")) {
        return TomlValue{ .boolean = true };
    }
    if (std.mem.eql(u8, clean_val, "false")) {
        return TomlValue{ .boolean = false };
    }

    // Числа (float или int)
    if (std.mem.indexOfScalar(u8, clean_val, '.')) |_| {
        const f = std.fmt.parseFloat(f64, clean_val) catch return TomlError.InvalidNumber;
        return TomlValue{ .float = f };
    }

    const int_val = std.fmt.parseInt(i64, clean_val, 10) catch return TomlError.InvalidNumber;
    return TomlValue{ .integer = int_val };
}

test "Парсинг TOML файла с массивами и секциями" {
    const toml_source =
        \\[server]
        \\port = 3222
        \\motd = "Привет \"Мир\"!"
        \\features = ["fast", "safe", "zig"]
        \\scores = [10, 20, 30]
    ;

    var doc = try parse(std.testing.allocator, toml_source);
    defer doc.deinit();

    try std.testing.expectEqual(@as(?u16, 3222), doc.getInt(u16, "server", "port"));
    try std.testing.expectEqualStrings("Привет \"Мир\"!", doc.getString("server", "motd").?);

    const feat_val = doc.get("server", "features").?;
    const feat_arr = feat_val.asArray().?;
    try std.testing.expectEqual(@as(usize, 3), feat_arr.len);
    try std.testing.expectEqualStrings("fast", feat_arr[0].asString().?);
    try std.testing.expectEqualStrings("safe", feat_arr[1].asString().?);
    try std.testing.expectEqualStrings("zig", feat_arr[2].asString().?);

    const score_val = doc.get("server", "scores").?;
    const score_arr = score_val.asArray().?;
    try std.testing.expectEqual(@as(i64, 10), score_arr[0].asInt(i64).?);
    try std.testing.expectEqual(@as(i64, 30), score_arr[2].asInt(i64).?);
}
