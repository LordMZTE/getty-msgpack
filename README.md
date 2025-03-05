# getty-msgpack

A [Getty](https://getty.so) (de)serializer for [MessagePack](https://msgpack.org).

## Supported Types

- ✅ - Supported
- ❎ - Not yet Supported
- 🔧 - Supported via a non-standard (de)serializer/visitor API

| Format                              | Serialization | Deserialization |
| ----------------------------------- | ------------- | --------------- |
| Nil                                 | ✅            | ✅              |
| Booleans                            | ✅            | ✅              |
| Integers (fixint and int/uint 8-64) | ✅            | ✅              |
| Floats                              | ✅            | ✅              |
| Strings                             | ✅            | ✅              |
| Maps (fixmap, map16, map32)         | ✅            | ✅              |
| Arrays (fixarray, array16, array32) | ✅            | ✅              |
| Bin (bin 8-32)                      | 🔧            | 🔧              |
| Ext (fixext 1-16 and ext 8-32)      | ❎            | ❎              |

## Related Projects

- [zig-msgpack](https://github.com/zigcc/zig-msgpack): An implementation of msgpack for Zig without
  Getty.
