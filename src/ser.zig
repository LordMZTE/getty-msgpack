const std = @import("std");
const getty = @import("getty");

/// A serializer for MessagePack
pub fn Serializer(
    comptime Writer: type,
    comptime sbt: anytype,
) type {
    return struct {
        writer: Writer,

        const Self = @This();

        pub usingnamespace getty.Serializer(
            *Self,
            void,
            Error,
            sbt,
            null,
            Seq,
            Seq,
            Seq,
            .{
                .serializeVoid = serializeNull,
                .serializeNull = serializeNull,
                .serializeBool = serializeBool,
                .serializeInt = serializeInt,
                .serializeFloat = serializeFloat,
                .serializeString = serializeString,
                .serializeEnum = serializeEnum,
                .serializeSeq = serializeSeq,
                .serializeMap = serializeMap,
                .serializeStruct = serializeStruct,
                .serializeSome = serializeSome,
            },
        );

        pub const Error = getty.ser.Error || Writer.Error || error{
            /// The integer is too big to be encoded by MsgPack
            IntegerTooLarge,

            /// The string or bytes are too long to be encoded by MsgPack
            StringTooLong,

            /// The sequence or map is too long to be encoded by MsgPack
            SeqTooLong,

            /// The length of a sequence or map has not been provided despite being necessary
            SeqLengthUnknown,

            /// The number of elements serialized in a sequence or map does not match the advertised count.
            SeqLengthMismatch,
        };

        // >>>>> NON-STANDARD CUSTOM FUNCTIONS

        /// A function to serialize a value as msgpack's bytes type. Useful with custom SBs.
        pub fn serializeBytes(self: *Self, val: []const u8) Error!void {
            inline for (.{ u8, u16, u32 }, 0..) |N, i| {
                if (val.len <= std.math.maxInt(N)) {
                    // bin: 0xc4 + i followed by BE length and data
                    try self.writer.writeByte(0xc4 + i);
                    try self.writer.writeInt(N, @intCast(i), .big);
                    try self.writer.writeAll(val);
                    break;
                }
            } else return error.StringTooLong;
        }
        // TODO: ext format?

        // >>>>> SERIALIZER INTERFACE

        fn serializeNull(self: *Self) Error!void {
            // nil: 0xc0
            try self.writer.writeByte(0xc0);
        }

        fn serializeBool(self: *Self, val: bool) Error!void {
            // true: 0xc3; false: 0xc2
            try self.writer.writeByte(0xc2 + @as(u8, @intFromBool(val)));
        }

        fn serializeInt(self: *Self, val: anytype) Error!void {
            if (val >= -32 and val <= 127) {
                // positive fixint: 0b0XXXXXXX
                // negative fixint: 0b111XXXXX
                try self.writer.writeByte(@bitCast(@as(i8, @intCast(val))));
            } else if (val >= 0) {
                // unsigned int
                inline for (.{ u8, u16, u32, u64 }, 0..) |N, i| {
                    if (val <= std.math.maxInt(N)) {
                        // uint: 0xcc + i followed by BE bytes
                        try self.writer.writeByte(0xcc + i);
                        try self.writer.writeInt(N, @intCast(val), .big);
                        break;
                    }
                } else return error.IntegerTooLarge;
            } else {
                inline for (.{ i8, i16, i32, i64 }, 0..) |N, i| {
                    if (val >= std.math.minInt(N)) {
                        // iint: 0xd0 + i follwed by BE bytes
                        try self.writer.writeByte(0xd0 + i);
                        try self.writer.writeInt(N, @intCast(val), .big);
                        break;
                    }
                } else return error.IntegerTooLarge;
            }
        }

        fn serializeFloat(self: *Self, val: anytype) Error!void {
            switch (@TypeOf(val)) {
                f32 => {
                    // f32: 0xca + IEEE 754 bytes
                    try self.writer.writeByte(0xca);
                    // HACK: we bitCast to an int here as byteSwap does not work on floats
                    try self.writer.writeInt(u32, @bitCast(val), .big);
                },
                comptime_float, f64 => {
                    // f64: 0xcb + IEEE 754 bytes
                    try self.writer.writeByte(0xcb);
                    try self.writer.writeInt(u64, @bitCast(@as(f64, val)), .big);
                },
                else => @compileError("Invalid type passed to serializeFloat: " ++ @typeName(@TypeOf(val))),
            }
        }

        fn serializeString(self: *Self, val_: anytype) Error!void {
            const val: []const u8 = val_;

            if (val.len <= 31) {
                // fixstr: 0b101XXXXX followed by bytes
                try self.writer.writeByte(0b10100000 | @as(u8, @intCast(val.len)));
                try self.writer.writeAll(val);
            } else {
                inline for (.{ u8, u16, u32 }, 0..) |N, i| {
                    if (val.len <= std.math.maxInt(N)) {
                        // str: 0d9 + i followed by BE len and bytes
                        try self.writer.writeByte(0xd9 + i);
                        try self.writer.writeInt(N, @intCast(val.len), .big);
                        try self.writer.writeAll(val);
                        break;
                    }
                } else return error.StringTooLong;
            }
        }

        fn serializeEnum(self: *Self, index: anytype, variant: []const u8) Error!void {
            _ = index;
            try self.serializeString(variant);
        }

        fn serializeSeq(self: *Self, len_: ?usize) Error!Seq {
            const len = len_ orelse return error.SeqLengthUnknown;

            if (len <= 15) {
                // fixarray: 0b1001XXXX
                try self.writer.writeByte(0b10010000 | @as(u8, @intCast(len)));
            } else {
                inline for (.{ u16, u32 }, 0..) |N, i| {
                    // array: 0xdc + i followed by BE length and elements
                    if (len <= std.math.maxInt(N)) {
                        try self.writer.writeByte(0xdc + i);
                        try self.writer.writeInt(N, @intCast(len), .big);
                        break;
                    }
                } else return error.SeqTooLong;
            }

            return .{ .ser = self, .len = len };
        }

        fn serializeMap(self: *Self, len_: ?usize) Error!Seq {
            const len = len_ orelse return error.SeqLengthUnknown;

            if (len <= 15) {
                // fixmap: 0b1000XXXX
                try self.writer.writeByte(0b10000000 | @as(u8, @intCast(len)));
            } else {
                inline for (.{ u16, u32 }, 0..) |N, i| {
                    // map: 0xde + i followed by BE length and elements (len * 2: k, v)
                    if (len <= std.math.maxInt(N)) {
                        try self.writer.writeByte(0xde + i);
                        try self.writer.writeInt(N, @intCast(len), .big);
                        break;
                    }
                } else return error.SeqTooLong;
            }

            return .{ .ser = self, .len = len * 2 };
        }

        fn serializeStruct(self: *Self, comptime name: []const u8, len: usize) Error!Seq {
            _ = name;
            return self.serializeMap(len);
        }

        fn serializeSome(self: *Self, val: anytype) Error!void {
            try getty.serialize(null, val, self.serializer());
        }

        const Seq = struct {
            ser: *Self,
            len: usize,
            nwritten: usize = 0,

            pub usingnamespace getty.ser.Seq(
                *Seq,
                void,
                Error,
                .{
                    .serializeElement = serializeElement,
                    .end = end,
                },
            );

            pub usingnamespace getty.ser.Map(
                *Seq,
                void,
                Error,
                .{
                    .serializeKey = serializeElement,
                    .serializeValue = serializeElement,
                    .end = end,
                },
            );

            pub usingnamespace getty.ser.Structure(
                *Seq,
                void,
                Error,
                .{
                    .serializeField = serializeField,
                    .end = end,
                },
            );

            fn serializeElement(self: *Seq, val: anytype) Error!void {
                // Too many elements
                if (self.nwritten == self.len) return error.SeqLengthMismatch;
                try getty.serialize(null, val, self.ser.serializer());
                self.nwritten += 1;
            }

            fn serializeField(self: *Seq, comptime key: []const u8, val: anytype) Error!void {
                try self.serializeElement(key);
                try self.serializeElement(val);
            }

            fn end(self: *Seq) Error!void {
                if (self.nwritten != self.len) return error.SeqLengthMismatch;
            }
        };
    };
}

/// Create a new `Serializer` with a given underlying writer and an SBT.
pub fn serializer(writer: anytype, sbt: anytype) Serializer(@TypeOf(writer), sbt) {
    return .{ .writer = writer };
}

/// Serialize the given value to the given writer, using a custom SBT.
pub fn serializeWith(writer: anytype, value: anytype, sbt: anytype) !void {
    var ser = serializer(writer, sbt);
    try getty.serialize(null, value, ser.serializer());
}

/// Serialize the given value to the given writer.
pub fn serialize(writer: anytype, value: anytype) !void {
    try serializeWith(writer, value, .{});
}

test "Serialize null/void" {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), null);
    try serialize(fbs.writer(), {});

    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0xc0 }, fbs.getWritten());
}

test "Serialize bool" {
    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), true);
    try serialize(fbs.writer(), false);

    try std.testing.expectEqualSlices(u8, &.{ 0xc3, 0xc2 }, fbs.getWritten());
}

test "Serialize int" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), 64); // pos fixint
    try serialize(fbs.writer(), -32); // neg fixint
    try serialize(fbs.writer(), std.math.maxInt(u16)); // u16
    try serialize(fbs.writer(), std.math.minInt(i16)); // i16
    try serialize(fbs.writer(), std.math.maxInt(u32)); // u32
    try serialize(fbs.writer(), std.math.minInt(i32)); // i32
    try std.testing.expectError(
        error.IntegerTooLarge,
        serialize(fbs.writer(), std.math.maxInt(u64) + 1),
    );

    try std.testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        64,
        @bitCast(@as(i8, -32)),
        0xcd, 0xff, 0xff,
        0xd1, 0x80, 0x00,
        0xce, 0xff, 0xff, 0xff, 0xff,
        0xd2, 0x80, 0x00, 0x00, 0x00,
        // zig fmt: on
    }, fbs.getWritten());
}

test "Serialize float" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), @as(f32, 0.5));
    try serialize(fbs.writer(), @as(f64, 0.5));
    try serialize(fbs.writer(), 0.5); // comptime_float

    try std.testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        0xca, 0x3f, 0x00, 0x00, 0x00,
        0xcb, 0x3f, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xcb, 0x3f, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // zig fmt: on
    }, fbs.getWritten());
}

test "Serialize string" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), "iiii"); // fixstr
    try serialize(fbs.writer(), "i" ** 32); // str8

    try std.testing.expectEqualSlices(u8, &[_]u8{
        // zig fmt: off
        0xa4, 0x69, 0x69, 0x69, 0x69,
        0xd9, 0x20,
        // zig fmt: on
    } ++ "i".* ** 32, fbs.getWritten());
}

test "Serialize enum" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), .foo);

    try std.testing.expectEqualSlices(u8, &.{
        0xa3, 0x66, 0x6f, 0x6f,
    }, fbs.getWritten());
}

test "Serialize array" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try serialize(fbs.writer(), [_]u8{105, 105}); // fixarray
    try serialize(fbs.writer(), [_]u8{105} ** 16); // array16

    try std.testing.expectEqualSlices(u8, &.{
        // zig fmt: off
        0x92, 0x69, 0x69,
        0xdc, 0x00, 0x10, 0x69, 0x69, 0x69, 0x69, 0x69, 0x69, 0x69, 0x69,
                          0x69, 0x69, 0x69, 0x69, 0x69, 0x69, 0x69, 0x69,
        // zig fmt: on
    }, fbs.getWritten());
}

test "Serialize map" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    // serializeMap
    try serialize(
        fbs.writer(),
        (union(enum){foo: []const u8}){.foo = "bar"},
    );

    // serializeStruct
    try serialize(
        fbs.writer(),
        .{.foo = "bar"},
    );

    try std.testing.expectEqualSlices(u8, &.{
        0x81, 0xa3, 0x66, 0x6f, 0x6f, 0xa3, 0x62, 0x61, 0x72,
        0x81, 0xa3, 0x66, 0x6f, 0x6f, 0xa3, 0x62, 0x61, 0x72,
    }, fbs.getWritten());
}
