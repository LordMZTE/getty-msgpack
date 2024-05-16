const std = @import("std");

pub const Format = union(enum) {
    /// Must be between -32 and 127
    fixint: i8,
    fixmap: u4,
    fixarray: u4,
    fixstr: u5,

    simple: SimpleFormat,

    pub fn fromByte(byte: u8) !Format {
        const ibyte: i8 = @bitCast(byte);
        if (ibyte <= 127 and ibyte >= -32) {
            return .{ .fixint = @bitCast(byte) };
        } else if (byte & 0xf0 == 0x80) {
            return .{ .fixmap = @truncate(byte) };
        } else if (byte & 0xf0 == 0x90) {
            return .{ .fixarray = @truncate(byte) };
        } else if (byte & 0xe0 == 0xa0) {
            return .{ .fixstr = @truncate(byte) };
        } else {
            return .{
                .simple = std.meta.intToEnum(SimpleFormat, byte) catch
                    return error.InvalidFormat,
            };
        }
    }

    /// Reads the length of the data stored in this format.
    /// For arrays and maps, returns the number of elements/key-value pairs.
    /// Will return 0 for types with no following data.
    /// For ext types, does not include the type byte.
    pub fn readLength(self: Format, reader: anytype) !u32 {
        return switch (self) {
            .fixint => return 0,
            .fixmap, .fixarray, .fixstr => |n| return n,
            .simple => |s| switch (s) {
                .nil, .false, .true => 0,
                .uint8, .int8, .fixext1 => 1,
                .uint16, .int16, .fixext2 => 2,
                .float32, .uint32, .int32, .fixext4 => 4,
                .float64, .uint64, .int64, .fixext8 => 8,
                .fixext16 => 16,
                .bin8, .ext8, .str8 => try reader.readByte(),
                .bin16, .ext16, .str16, .array16, .map16 => try reader.readInt(u16, .big),
                .bin32, .ext32, .str32, .array32, .map32 => try reader.readInt(u32, .big),
            },
        };
    }
};

pub const SimpleFormat = enum(u8) {
    nil = 0xc0,
    false = 0xc2,
    true = 0xc3,
    bin8 = 0xc4,
    bin16 = 0xc5,
    bin32 = 0xc6,
    ext8 = 0xc7,
    ext16 = 0xc8,
    ext32 = 0xc9,
    float32 = 0xca,
    float64 = 0xcb,
    uint8 = 0xcc,
    uint16 = 0xcd,
    uint32 = 0xce,
    uint64 = 0xcf,
    int8 = 0xd0,
    int16 = 0xd1,
    int32 = 0xd2,
    int64 = 0xd3,
    fixext1 = 0xd4,
    fixext2 = 0xd5,
    fixext4 = 0xd6,
    fixext8 = 0xd7,
    fixext16 = 0xd8,
    str8 = 0xd9,
    str16 = 0xda,
    str32 = 0xdb,
    array16 = 0xdc,
    array32 = 0xdd,
    map16 = 0xde,
    map32 = 0xdf,
};
