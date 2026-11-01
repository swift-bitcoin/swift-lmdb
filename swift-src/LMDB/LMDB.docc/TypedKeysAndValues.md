# Typed Keys and Values

Encode and decode Swift types with byte representations that preserve natural sort order in LMDB's B-tree.

## Overview

Any type conforming to ``LMDBEncodable`` can be stored as a key or value, and any type conforming to ``LMDBDecodable`` can be decoded back from the database:

```swift
try txn.put(reading, forKey: Date.now, in: sensorLog)

let cursor = try Cursor(txn, database: sensorLog)
let latest = try cursor.last()?.value(as: Double.self)
```

## Order-Preserving Encodings

LMDB orders keys in its B-tree by comparing their bytes lexicographically (`memcmp` by default). Each built-in conformance to ``LMDBCodable`` uses a byte representation whose unsigned lexicographical order matches the type's natural Swift order, so cursor iteration and range scans with ``Cursor/seek(atOrAfter:)-(LMDBEncodable)`` work naturally on numbers, dates, strings, and UUIDs:

| Type | Encoding | Key Order |
|---|---|---|
| `Int`, `Int8`…`Int64` | Fixed-width big-endian with sign bit flipped (`value ^ .min`) | Numeric, negatives first |
| `UInt`, `UInt8`…`UInt64` | Fixed-width big-endian | Numeric |
| `Double`, `Float` | IEEE 754 bits; sign bit set if non-negative, all bits inverted if negative | Numeric, `-inf` … `-0` < `+0` … `+inf` |
| `Date` | `timeIntervalSinceReferenceDate` encoded as `Double` | Chronological |
| `Bool` | One byte, `0` or `1` | `false` before `true` |
| `String` | UTF-8 bytes (decoding validates UTF-8 and throws on invalid sequences) | Unicode scalar value |
| `[UInt8]`, `Data` | Raw bytes | Lexicographical byte order |
| `UUID` | 16 raw UUID bytes | Same as `uuidString` |

> Important: `Int` and `UInt` are 8 bytes on 64-bit platforms and 4 bytes on 32-bit platforms. Use explicitly sized integer types (`Int64`, `UInt32`, etc.) when database files may be read across architectures. Do not combine these encodings with ``DatabaseOptions/integerKey`` or ``DatabaseOptions/integerDuplicate``, which expect native-endian unsigned integers.

## Why Big-Endian Instead of `.integerKey`?

LMDB's `MDB_INTEGERKEY` (``DatabaseOptions/integerKey``) compares keys as native-endian unsigned C integers (`unsigned int` or `size_t`). Encoding integers as big-endian bytes under LMDB's default bytewise comparator is more general:

- **Composite keys work.** Big-endian fields concatenated together sort field by field, such as a `(height, index)` pair or a 2D coordinate. ``DatabaseOptions/integerKey`` only works when the *entire* key is a single integer.
- **Signed integers sort properly.** ``DatabaseOptions/integerKey`` compares keys as unsigned, placing negative two's-complement numbers *after* positive ones. Flipping the sign bit in big-endian order maps `min...max` onto `0...UInt.max` in true numeric order.
- **Any integer width works.** ``DatabaseOptions/integerKey`` requires every key in the database to be the exact same size, and only supports 4-byte or `size_t`-sized integers.
- **One consistent API.** Range scans with ``Cursor/seek(atOrAfter:)-(LMDBEncodable)`` work identically across integers, floats, dates, strings, and custom composite keys.

## Custom Types

To store your own types, conform to ``LMDBEncodable`` and ``LMDBDecodable`` (or the combined ``LMDBCodable`` typealias) by implementing ``LMDBEncodable/encodedByteCount``, ``LMDBEncodable/encode(into:)``, and ``LMDBDecodable/init(lmdbBytes:)``:

```swift
struct GridPoint: LMDBCodable {
    var x, y: Int32

    var encodedByteCount: Int { 8 }

    func encode(into output: inout OutputRawSpan) {
        x.encode(into: &output)            // sorts by x, then y
        y.encode(into: &output)
    }

    init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        guard bytes.byteCount == 8 else {
            throw LMDBDecodingError(Self.self, byteCount: bytes.byteCount, reason: "expected 8 bytes")
        }
        x = try Int32(lmdbBytes: bytes.extracting(0..<4))
        y = try Int32(lmdbBytes: bytes.extracting(4..<8))
    }
}
```

## In-Place Encoding and Zero-Copy Paths

Typed operations avoid unnecessary allocations and copies:

- **Keys** are encoded into a stack allocation via `withTemporaryAllocation(byteCount:alignment:)`.
- **Contiguous byte types** (`String`, `[UInt8]`, and `Data`) override ``LMDBEncodable/withEncodedBytes(_:)`` to pass their existing buffer directly without copying.
- **Values are encoded straight into the memory map** (`MDB_RESERVE`) via ``WriteTransaction/put(reservingByteCount:forKey:in:options:initializingWith:)-(Int,RawSpan,_,_,_)`` whenever the database does not use ``DatabaseOptions/duplicateSort``.
- **Safe endian-aware primitives**: All built-in conformances use bounds-checked `RawSpan.load(fromByteOffset:as:_:)` and `OutputRawSpan.append(_:as:_:)` with no `unsafe` code.

### Reserving Space Directly (`MDB_RESERVE`)

You can also reserve space in the database directly and populate it in place through an `OutputRawSpan`:

```swift
try txn.put(reservingByteCount: 12, forKey: id, in: db) { out in
    out.append(header, as: UInt32.self, .bigEndian)
    out.append(timestamp, as: UInt64.self, .bigEndian)
}
```

LMDB does not zero-initialize reserved pages, which may contain stale bytes from previously deleted records. Providing an append-only `OutputRawSpan` ensures your initializer cannot read uninitialized memory, and the wrapper verifies that the closure writes the exact number of reserved bytes before returning.
