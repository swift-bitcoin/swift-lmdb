# LMDB for Swift — Safe Interop Layer

A fork of [swiftlang/swift-lmdb](https://github.com/swiftlang/swift-lmdb) that adds a
minimal, memory-safe Swift API on top of LMDB, driven by hand-written
[API notes](https://clang.llvm.org/docs/APINotes.html) and Swift's `SafeInteropWrappers`.

Everything new lives in `swift-*` folders at the root, so merging from upstream only ever
conflicts in `Package.swift`:

```
swift-include/module.modulemap          CLMDBInterop: a second view of lmdb.h
swift-include/CLMDBInterop.apinotes     hand-written annotations for that view
swift-src/LMDB/                         the Swift wrapper (module LMDB)
swift-src/LMDB/LMDB.docc/               DocC documentation catalog and articles
swift-test/LMDBTests/                   Swift Testing suite
swift-test/CompileFailures/             code that must NOT compile
swift-test/check-compile-failures.sh    checks that it doesn't
```

`libraries/liblmdb/` and `Sources/CLMDB/` are untouched, and the `CLMDB` module imports
exactly as before, so existing users (for example `swift-docc`) are unaffected by the
annotations.

## Requirements

- Swift **6.4** (`swift-tools-version: 6.4`)
- macOS **27+**:
  - `Span` and `MutableSpan` require macOS 26. With a lower deployment target the importer
    *silently* emits `UnsafeBufferPointer` overloads instead of `Span` ones.
  - Typed keys and values use the safe, endian-aware `RawSpan.load` and
    `OutputRawSpan.append`, which require macOS 27.

## Quick Start

```swift
import LMDB

let env = try Environment(path: directory, maxDatabases: 2)   // directory must exist
let users = try env.openDatabase(named: "users")

// Typed keys and values: Int, String, Date, UUID, Data, [UInt8], ...
try env.write { txn in
    try txn.put("Alice", forKey: 42, in: users)
    try txn.insert("Bob", forKey: 7, in: users)       // only if 7 is not taken
    try txn.delete(forKey: 13, in: users)
}

try env.read { txn in
    let name: String? = try txn.value(forKey: 42, in: users)

    // Zero-copy: a RawSpan straight into the memory map, valid for this transaction only.
    if let bytes = try txn.value(forKey: 42, in: users) {
        print(bytes.byteCount)
    }
}

// Closures are conveniences; transactions are also plain values.
var txn = try WriteTransaction(env)
try txn.put("Carol", forKey: 99, in: users)
try txn.commit()          // consuming; dropping it instead aborts
```

Every operation also has a `RawSpan` form for bytes you already have
(`txn.put(data.bytes, forKey: key.span.bytes, in: db)`).

| Type | Overview |
|---|---|
| `Environment` | `~Copyable` owner of an `MDB_env`; closes it in `deinit`. |
| `Database` | Value-type database handle (`MDB_dbi`) and its `DatabaseOptions`. |
| `ReadTransaction` / `WriteTransaction` | `~Copyable, ~Escapable` transactions borrowing the environment. |
| `ResetReadTransaction` | `~Copyable, ~Escapable` reset read transaction ready to `renew()`. |
| `Cursor<ReadOnly>` / `Cursor<ReadWrite>` | `~Copyable, ~Escapable` B-tree cursors dependent on a transaction. |
| `CursorEntry` / `DuplicateBatch` | `~Escapable` zero-copy `RawSpan` views into the memory map. |
| `LMDBEncodable` / `LMDBDecodable` | Order-preserving encoding and decoding for typed keys and values. |
| `LMDBError` / `LMDBDecodingError` | Typed LMDB return codes and decoding diagnostics. |

## Documentation

Detailed guides and API reference live in the DocC catalog at [`swift-src/LMDB/LMDB.docc`](swift-src/LMDB/LMDB.docc):

- [**LMDB Overview**](swift-src/LMDB/LMDB.docc/LMDB.md) — Module overview and symbol index.
- [**Compile-Time Safety and Lifetimes**](swift-src/LMDB/LMDB.docc/Safety.md) — What the compiler enforces (`~Copyable`, `~Escapable`, `@_lifetime`, `noasync`), thread safety, closure vs. standalone transactions, and where `unsafe` remains.
- [**Typed Keys and Values**](swift-src/LMDB/LMDB.docc/TypedKeysAndValues.md) — Order-preserving encodings, why big-endian is preferred over `.integerKey`, custom `LMDBCodable` types, and in-place writes with `MDB_RESERVE`.
- [**Cursors and Iteration**](swift-src/LMDB/LMDB.docc/Cursors.md) — Read-only and read-write cursors, range and prefix scans, duplicate navigation, fixed-size batches, and LMDB edge cases handled by the wrapper.
- [**C Interop and API Notes**](swift-src/LMDB/LMDB.docc/CInteropAndAPINotes.md) — How `CLMDBInterop` is separated from `CLMDB`, the `counted_by: 1` pattern with `CollectionOfOne`, and why 12 C functions are intentionally omitted.
- [**Migrating from swift-bitcoin's Wrapper**](swift-src/LMDB/LMDB.docc/MigratingFromSwiftBitcoin.md) — Side-by-side API mapping and idioms for migrating from `swift-bitcoin`'s `src/lmdb`.

## Testing

```sh
swift test                                # runtime behaviour
swift test --sanitize=address             # ... including cursor/commit ordering
swift-test/check-compile-failures.sh      # compile-time guarantees
```

## Changes to Upstream Files

- `Package.swift`:
  - tools version `5.0` → `6.4`, `platforms: [.macOS(.v27)]`
  - new `LMDB` library product and `CLMDBInterop`, `LMDB`, and `LMDBTests` targets
  - `.strictMemorySafety()` with `.treatWarning("StrictMemorySafety", as: .error)` on the Swift targets
  - in `CLMDB`, `.unsafeFlags(["-Wno-shorten-64-to-32"])` replaced with `.disableWarning("shorten-64-to-32")` so the package can be used as a remote dependency
- Nothing else: `libraries/liblmdb/`, `Sources/CLMDB/`, and `CMakeLists.txt` are untouched.
