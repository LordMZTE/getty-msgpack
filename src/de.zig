const std = @import("std");
const getty = @import("getty");

const Format = @import("lib.zig").Format;

pub fn Deserializer(comptime Reader: type, comptime dbt: anytype) type {
    return struct {
        reader: Reader,
        buffered_format: ?Format = null,

        pub const Self = @This();

        pub usingnamespace getty.Deserializer(
            *Self,
            Error,
            dbt,
            null,
            .{
                .deserializeAny = deserializeAny,
                .deserializeIgnored = deserializeIgnored,
                .deserializeBool = deserializeBool,
                .deserializeInt = deserializeInt,
                .deserializeFloat = deserializeFloat,
                .deserializeOptional = deserializeOptional,
                .deserializeString = deserializeString,
                .deserializeEnum = deserializeEnum,
                .deserializeVoid = deserializeVoid,
                .deserializeMap = deserializeMap,
                .deserializeStruct = deserializeMap,
                .deserializeSeq = deserializeSeq,
                .deserializeUnion = deserializeUnion,
            },
        );

        const De = Self.@"getty.Deserializer";

        pub const Error = getty.de.Error || std.mem.Allocator.Error || Reader.Error || Reader.NoEofError || error{
            /// An invalid byte
            InvalidFormat,
        };

        fn readNBytes(self: *Self, arena: std.mem.Allocator, n: usize) ![]u8 {
            // TODO: use buffer and don't always alloc
            const buf = try arena.alloc(u8, n);
            const read = try self.reader.readAll(buf);
            if (read != n) return error.EndOfStream;
            return buf;
        }

        fn nextFormat(self: *Self) !Format {
            if (self.buffered_format) |f| {
                self.buffered_format = null;
                return f;
            }
            return try Format.fromByte(try self.reader.readByte());
        }

        fn skipValue(self: *Self) !void {
            const fmt = try self.nextFormat();
            switch (fmt) {
                .fixint => {},
                .fixmap => |n| for (0..n * 2) |_| {
                    try skipValue(self);
                },
                .fixarray => |n| for (0..n) |_| {
                    try skipValue(self);
                },
                .fixstr => |n| {
                    try self.reader.skipBytes(n, .{});
                },
                .simple => |s| switch (s) {
                    .fixext1, .fixext2, .fixext4, .fixext8, .fixext16, .ext8, .ext16, .ext32 => {
                        const len = try fmt.readLength(self.reader);
                        // Skip data + type byte
                        try self.reader.skipBytes(@as(usize, len) + 1, .{});
                    },
                    .map16, .map32 => {
                        const len = try fmt.readLength(self.reader);
                        for (0..len * 2) |_| {
                            try skipValue(self);
                        }
                    },
                    .array16, .array32 => {
                        const len = try fmt.readLength(self.reader);
                        for (0..len) |_| {
                            try skipValue(self);
                        }
                    },
                    else => {
                        const len = try fmt.readLength(self.reader);
                        try self.reader.skipBytes(len, .{});
                    },
                },
            }
        }

        fn deserializeAny(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            switch (fmt) {
                .fixint => |n| {
                    return try vis.visitInt(arena, De, n);
                },
                .fixmap => |len| {
                    var map = MapAccess{ .de = self, .nfields = len };
                    const ret = try vis.visitMap(arena, De, map.mapAccess());
                    if (map.nfields != 0) return error.InvalidLength;
                    return ret;
                },
                .fixarray => |len| {
                    var seq = SeqAccess{ .de = self, .len = len };
                    const ret = try vis.visitSeq(arena, De, seq.seqAccess());
                    if (seq.len != 0) return error.InvalidLength;
                    return ret;
                },
                .fixstr => |len| {
                    const str = try self.readNBytes(arena, len);
                    return try vis.visitString(arena, De, str, .heap);
                },
                .simple => |s| switch (s) {
                    .nil => return try vis.visitNull(arena, De),
                    .false, .true => try vis.visitBool(arena, De, s == .true),
                    .uint8 => return try vis.visitInt(arena, De, try self.reader.readInt(u8, .big)),
                    .uint16 => return try vis.visitInt(arena, De, try self.reader.readInt(u16, .big)),
                    .uint32 => return try vis.visitInt(arena, De, try self.reader.readInt(u32, .big)),
                    .uint64 => return try vis.visitInt(arena, De, try self.reader.readInt(u64, .big)),
                    .int8 => return try vis.visitInt(arena, De, try self.reader.readInt(i8, .big)),
                    .int16 => return try vis.visitInt(arena, De, try self.reader.readInt(i16, .big)),
                    .int32 => return try vis.visitInt(arena, De, try self.reader.readInt(i32, .big)),
                    .int64 => return try vis.visitInt(arena, De, try self.reader.readInt(i64, .big)),
                    .float32 => return try vis.visitFloat(arena, De, @as(f32, @bitCast(try self.reader.readInt(u32, .big)))),
                    .float64 => return try vis.visitFloat(arena, De, @as(f32, @bitCast(try self.reader.readInt(u64, .big)))),
                    .str8, .str16, .str32 => {
                        const len = try fmt.readLength(self.reader);
                        const str = try self.readNBytes(arena, len);
                        try vis.visitString(arena, De, str, .heap);
                    },
                    .array16, .array32 => {
                        const len = try fmt.readLength(self.reader);
                        var seq = SeqAccess{ .de = self, .len = len };
                        const ret = try vis.visitSeq(arena, De, seq.seqAccess());
                        if (seq.len != 0) return error.InvalidLength;
                        return ret;
                    },
                    .map16, .map32 => {
                        const len = try fmt.readLength(self.reader);
                        var map = MapAccess{ .de = self, .nfields = len };
                        const ret = try vis.visitMap(arena, De, map.mapAccess());
                        if (map.nfields != 0) return error.InvalidLength;
                        return ret;
                    },
                    .fixext1, .fixext2, .fixext4, .fixext8, .fixext16, .ext8, .ext16, .ext32 => {
                        // A visitor may optionally implement a visitExt function, which is invoked here.
                        // Signature: fn(
                        //     self: Impl,
                        //     arena: std.mem.Allocator,
                        //     comptime Deseriailzer: type,
                        //     type_byte: u8,
                        //     data: []u8,
                        //     life: StringLifetime,
                        // ) Error!Value
                        if (!@hasDecl(vis.impl, "visitExt"))
                            return error.Unsupported;

                        const len = try fmt.readLength(self.reader);
                        const type_byte = try self.reader.readByte();
                        const data = try self.readNBytes(arena, len);
                        return try vis.impl.visitExt(arena, De, type_byte, data, .heap);
                    },

                    .bin8, .bin16, .bin32 => {
                        // A visitor may optionally implement a visitBin function, which is invoked here.
                        // Signature: fn(
                        //     self: Impl,
                        //     arena: std.mem.Allocator,
                        //     comptime Deseriailzer: type,
                        //     data: []u8,
                        //     life: StringLifetime,
                        // ) Error!Value
                        if (!@hasDecl(vis.impl, "visitBin"))
                            return error.Unsupported;

                        const len = try fmt.readLength(self.reader);
                        const data = try self.readNBytes(arena, len);
                        return try vis.impl.visitBin(arena, De, data, .heap);
                    },
                },
            }
        }

        fn deserializeIgnored(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            try self.skipValue();
            return try vis.visitVoid(arena, De);
        }

        fn deserializeBool(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .simple => |s| switch (s) {
                    .true, .false => try vis.visitBool(arena, De, s == .true),
                    else => error.InvalidType,
                },
                else => return error.InvalidType,
            };
        }

        fn deserializeInt(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .fixint => |n| try vis.visitInt(arena, De, n),
                .simple => |s| switch (s) {
                    .uint8 => try vis.visitInt(arena, De, try self.reader.readInt(u8, .big)),
                    .uint16 => try vis.visitInt(arena, De, try self.reader.readInt(u16, .big)),
                    .uint32 => try vis.visitInt(arena, De, try self.reader.readInt(u32, .big)),
                    .uint64 => try vis.visitInt(arena, De, try self.reader.readInt(u64, .big)),
                    .int8 => try vis.visitInt(arena, De, try self.reader.readInt(i8, .big)),
                    .int16 => try vis.visitInt(arena, De, try self.reader.readInt(i16, .big)),
                    .int32 => try vis.visitInt(arena, De, try self.reader.readInt(i32, .big)),
                    .int64 => try vis.visitInt(arena, De, try self.reader.readInt(i64, .big)),
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        fn deserializeFloat(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .simple => |s| switch (s) {
                    .float32 => try vis.visitFloat(arena, De, @as(
                        f32,
                        @bitCast(try self.reader.readInt(u32, .big)),
                    )),
                    .float64 => try vis.visitFloat(arena, De, @as(
                        f64,
                        @bitCast(try self.reader.readInt(u64, .big)),
                    )),
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        fn deserializeOptional(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            switch (fmt) {
                .simple => |s| switch (s) {
                    .nil => return try vis.visitNull(arena, De),
                    else => {},
                },
                else => {},
            }

            self.buffered_format = fmt;
            return try vis.visitSome(arena, self.deserializer());
        }

        fn deserializeString(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            switch (fmt) {
                .fixstr => |n| {
                    const str = try self.readNBytes(arena, n);
                    return (try vis.visitString(arena, De, str, .heap)).value;
                },
                .simple => |s| switch (s) {
                    .str8, .str16, .str32 => {
                        const n = try fmt.readLength(self.reader);
                        const str = try self.readNBytes(arena, n);
                        return (try vis.visitString(arena, De, str, .heap)).value;
                    },
                    else => return error.InvalidType,
                },
                else => return error.InvalidType,
            }
        }

        fn deserializeEnum(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .fixstr => |n| {
                    const str = try self.readNBytes(arena, n);
                    return (try vis.visitString(arena, De, str, .heap)).value;
                },
                .fixint => |n| try vis.visitInt(arena, De, n),
                .simple => |s| switch (s) {
                    .str8, .str16, .str32 => {
                        const n = try fmt.readLength(self.reader);
                        const str = try self.readNBytes(arena, n);
                        return (try vis.visitString(arena, De, str, .heap)).value;
                    },
                    .uint8 => try vis.visitInt(arena, De, try self.reader.readInt(u8, .big)),
                    .uint16 => try vis.visitInt(arena, De, try self.reader.readInt(u16, .big)),
                    .uint32 => try vis.visitInt(arena, De, try self.reader.readInt(u32, .big)),
                    .uint64 => try vis.visitInt(arena, De, try self.reader.readInt(u64, .big)),
                    .int8 => try vis.visitInt(arena, De, try self.reader.readInt(i8, .big)),
                    .int16 => try vis.visitInt(arena, De, try self.reader.readInt(i16, .big)),
                    .int32 => try vis.visitInt(arena, De, try self.reader.readInt(i32, .big)),
                    .int64 => try vis.visitInt(arena, De, try self.reader.readInt(i64, .big)),
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        fn deserializeVoid(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .simple => |s| switch (s) {
                    .nil => try vis.visitVoid(arena, De),
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        fn deserializeMap(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .fixmap => |n| {
                    var map = MapAccess{ .de = self, .nfields = n };
                    const ret = try vis.visitMap(arena, De, map.mapAccess());
                    if (map.nfields != 0) return error.InvalidLength;
                    return ret;
                },
                .simple => |s| switch (s) {
                    .map16, .map32 => {
                        const len = try fmt.readLength(self.reader);
                        var map = MapAccess{ .de = self, .nfields = len };
                        const ret = try vis.visitMap(arena, De, map.mapAccess());
                        if (map.nfields != 0) return error.InvalidLength;
                        return ret;
                    },
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        fn deserializeSeq(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .fixarray => |n| {
                    var seq = SeqAccess{ .de = self, .len = n };
                    const ret = try vis.visitSeq(arena, De, seq.seqAccess());
                    if (seq.len != 0) return error.InvalidLength;
                    return ret;
                },
                .simple => |s| switch (s) {
                    .array16, .array32 => {
                        const n = try fmt.readLength(self.reader);
                        var seq = SeqAccess{ .de = self, .len = n };
                        const ret = try vis.visitSeq(arena, De, seq.seqAccess());
                        if (seq.len != 0) return error.InvalidLength;
                        return ret;
                    },
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        fn deserializeUnion(self: *Self, arena: std.mem.Allocator, vis: anytype) Error!@TypeOf(vis).Value {
            const fmt = try self.nextFormat();
            return switch (fmt) {
                .fixmap => |n| {
                    if (n != 1) return error.InvalidType;
                    var u = UnionAccess{ .de = self };
                    return try vis.visitUnion(arena, De, u.unionAccess(), u.variantAccess());
                },
                .simple => |s| switch (s) {
                    .map16, .map32 => {
                        const len = try fmt.readLength(self.reader);
                        if (len != 1) return error.InvalidType;
                        var u = UnionAccess{ .de = self };
                        return try vis.visitUnion(arena, De, u.unionAccess(), u.variantAccess());
                    },
                    else => error.InvalidType,
                },
                else => error.InvalidType,
            };
        }

        pub const SeqAccess = struct {
            de: *Self,
            len: usize,

            pub usingnamespace getty.de.SeqAccess(
                *SeqAccess,
                Error,
                .{ .nextElementSeed = nextElementSeed },
            );

            fn nextElementSeed(
                self: *SeqAccess,
                arena: std.mem.Allocator,
                seed: anytype,
            ) Error!?@TypeOf(seed).Value {
                if (self.len == 0) return null;
                self.len -= 1;

                return try seed.deserialize(arena, self.de.deserializer());
            }
        };

        pub const MapAccess = struct {
            de: *Self,
            nfields: usize,

            pub usingnamespace getty.de.MapAccess(*MapAccess, Error, .{
                .nextKeySeed = nextKeySeed,
                .nextValueSeed = nextValueSeed,
            });

            fn nextKeySeed(
                self: *MapAccess,
                arena: std.mem.Allocator,
                seed: anytype,
            ) Error!?@TypeOf(seed).Value {
                if (self.nfields == 0) return null;
                self.nfields -= 1;
                return try seed.deserialize(arena, self.de.deserializer());
            }

            fn nextValueSeed(
                self: *MapAccess,
                arena: std.mem.Allocator,
                seed: anytype,
            ) Error!@TypeOf(seed).Value {
                return try seed.deserialize(arena, self.de.deserializer());
            }
        };

        pub const UnionAccess = struct {
            de: *Self,

            pub usingnamespace getty.de.UnionAccess(
                *UnionAccess,
                Error,
                .{ .variantSeed = fromSeed },
            );

            pub usingnamespace getty.de.VariantAccess(
                *UnionAccess,
                Error,
                .{ .payloadSeed = fromSeed },
            );

            fn fromSeed(self: *UnionAccess, arena: std.mem.Allocator, seed: anytype) Error!@TypeOf(seed).Value {
                return try seed.deserialize(arena, self.de.deserializer());
            }
        };
    };
}

pub fn deserializer(reader: anytype, dbt: anytype) Deserializer(@TypeOf(reader), dbt) {
    return .{ .reader = reader };
}

pub fn deserializeWith(
    alloc: std.mem.Allocator,
    comptime T: type,
    reader: anytype,
    dbt: anytype,
) !getty.de.Result(T) {
    var de = deserializer(reader, dbt);
    return try getty.deserialize(alloc, T, de.deserializer());
}

pub fn deserialize(
    alloc: std.mem.Allocator,
    comptime T: type,
    reader: anytype,
) !getty.de.Result(T) {
    return try deserializeWith(alloc, T, reader, .{});
}

test "Deserialize Ignored" {
    const data = [_]u8{ 0xa4, 0x41, 0x4c, 0x45, 0x43 };
    var fbs = std.io.fixedBufferStream(&data);

    const res = try deserialize(std.testing.allocator, getty.de.Ignored, fbs.reader());
    defer res.deinit();

    try std.testing.expectEqual(data.len, fbs.pos);
}

test "Deserialize bool" {
    const data = [_]u8{ 0xc2, 0xc3 };
    var fbs = std.io.fixedBufferStream(&data);

    inline for (.{ false, true }) |exp| {
        const res = try deserialize(std.testing.allocator, bool, fbs.reader());
        defer res.deinit();

        try std.testing.expectEqual(exp, res.value);
    }
}

test "Deserialize int" {
    const data = [_]u8{
        0x45, // positive fixint
        0xf0, // negative fixint
        0xcd, 0x04, 0x00, // uint16
    };
    var fbs = std.io.fixedBufferStream(&data);

    inline for (.{ 69, -16, 1024 }) |exp| {
        const res = try deserialize(std.testing.allocator, i32, fbs.reader());
        defer res.deinit();

        try std.testing.expectEqual(exp, res.value);
    }
}

test "Deserialize float" {
    const data = [_]u8{
        // zig fmt: off
        0xca, 0x3f, 0x00, 0x00, 0x00, // 0.5 f32
        0xcb, 0x3f, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0.5 f64
        // zig fmt: on
    };
    var fbs = std.io.fixedBufferStream(&data);

    const res32 = try deserialize(std.testing.allocator, f32, fbs.reader());
    defer res32.deinit();

    try std.testing.expectEqual(@as(f32, 0.5), res32.value);

    const res64 = try deserialize(std.testing.allocator, f64, fbs.reader());
    defer res64.deinit();

    try std.testing.expectEqual(@as(f64, 0.5), res64.value);
}

test "Deserialize optional" {
    const data = [_]u8{
        // zig fmt: off
        0xc0, // nil
        0xc3, // true
        // zig fmt: on
    };
    var fbs = std.io.fixedBufferStream(&data);

    inline for (.{null, true}) |exp| {
        const res = try deserialize(std.testing.allocator, ?bool, fbs.reader());
        defer res.deinit();

        try std.testing.expectEqual(exp, res.value);
    }
}

test "Deserialize string" {
    const data = [_]u8{
        0xa4, 0x74, 0x65, 0x73, 0x74, // fixtr
        0xd9, 0x20, // str8
    } ++ [_]u8{0x69} ** 32;
    var fbs = std.io.fixedBufferStream(&data);

    inline for (.{"test", "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii"}) |exp| {
        const res = try deserialize(std.testing.allocator, []const u8, fbs.reader());
        defer res.deinit();

        try std.testing.expectEqualStrings(exp, res.value);
    }
}

test "Deserialize struct" {
    const data = [_]u8{
        // zig fmt: off
        0x82, // fixmap 2
        0xa3, 0x6e, 0x75, 0x6d, // fixstr "num"
        0x2a, // fixint 42
        0xa3, 0x73, 0x74, 0x72, // fixstr "str"
        0xa4, 0x74, 0x65, 0x73, 0x74, // fixstr "test"
        // zig fmt: on
    };
    var fbs = std.io.fixedBufferStream(&data);

    const Test = struct {
        num: u8,
        str: []const u8,
    };

    const res = try deserialize(std.testing.allocator, Test, fbs.reader());
    defer res.deinit();

    try std.testing.expectEqualDeep(Test{
        .num = 42,
        .str = "test",
    }, res.value);
}

test "Deserialize tuple" {
    const data = [_]u8{
        // zig fmt: off
        0x92, // fixarray 2
        0x2a, // fixint 42
        0xa4, 0x74, 0x65, 0x73, 0x74, // fixstr "test"
        // zig fmt: on
    };
    var fbs = std.io.fixedBufferStream(&data);

    const Test = struct { u32, []const u8 };

    const res = try deserialize(std.testing.allocator, Test, fbs.reader());
    defer res.deinit();

    try std.testing.expectEqualDeep(Test{ 42, "test" }, res.value);
}

test "Deserialize enum" {
    const data = [_]u8{
        // zig fmt: off
        0xa3, 0x66, 0x6f, 0x6f, // fixstr "foo"
        // zig fmt: on
    };
    var fbs = std.io.fixedBufferStream(&data);

    const Test = enum { foo, bar };

    const res = try deserialize(std.testing.allocator, Test, fbs.reader());
    defer res.deinit();

    try std.testing.expectEqualDeep(Test.foo, res.value);
}

test "Deserialize union" {
    const data = [_]u8{
        // zig fmt: off
        0x81, // fixmap 1
        0xa3, 0x66, 0x6f, 0x6f, // fixstr "foo"
        0x2a, // fixint 42
        // zig fmt: on
    };
    var fbs = std.io.fixedBufferStream(&data);

    const Test = union(enum) { foo: u8, bar };

    const res = try deserialize(std.testing.allocator, Test, fbs.reader());
    defer res.deinit();

    try std.testing.expectEqualDeep(Test{.foo = 42}, res.value);
}
