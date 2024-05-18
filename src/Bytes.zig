const std = @import("std");
const getty = @import("getty");

data: []const u8,

const Bytes = @This();

pub const @"getty.sb" = struct {
    pub fn serialize(
        alloc: ?std.mem.Allocator,
        val: anytype,
        ser: anytype,
    ) @TypeOf(ser).Err!@TypeOf(ser).Ok {
        _ = alloc;
        return try ser.impl.serializeBin(val.data);
    }
};

pub const @"getty.db" = struct {
    pub fn deserialize(
        alloc: std.mem.Allocator,
        comptime T: type,
        de: anytype,
        vis: anytype,
    ) @TypeOf(de).Err!@TypeOf(vis).Value {
        comptime std.debug.assert(T == Bytes);
        return try de.impl.deserializeBin(alloc, vis);
    }

    pub fn Visitor(comptime T: type) type {
        comptime std.debug.assert(T == Bytes);
        return struct {
            const Self = @This();

            pub usingnamespace getty.de.Visitor(
                Self,
                Bytes,
                .{},
            );

            pub fn visitBin(
                self: Self,
                alloc: std.mem.Allocator,
                comptime De: type,
                data: []u8,
                life: getty.de.StringLifetime,
            ) De.Err!Bytes {
                _ = self;
                _ = alloc;
                _ = life;
                return .{ .data = data };
            }
        };
    }
};
