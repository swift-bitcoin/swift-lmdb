# ``LMDB``

A memory-safe Swift wrapper around LMDB, built on Clang API notes and Swift's safe C interop (`Span`, `RawSpan`, `~Copyable`, and `~Escapable`).

## Overview

`LMDB` provides a minimal, zero-copy Swift interface to the Symas Lightning Memory-Mapped Database. Ownership and lifetime rules that LMDB leaves to the C caller are expressed directly in the Swift type system, so use-after-free, dangling spans, and overlapping read/write accesses fail at compile time rather than corrupting memory at runtime.

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

// The closures are conveniences; transactions are also plain values.
var txn = try WriteTransaction(env)
try txn.put("Carol", forKey: 99, in: users)
try txn.commit()          // consuming; dropping it instead aborts
```

Every operation has both a `RawSpan` form for raw bytes and a typed form for ``LMDBEncodable`` and ``LMDBDecodable`` types.

## Topics

### Guides

- <doc:Safety>
- <doc:TypedKeysAndValues>
- <doc:Cursors>
- <doc:CInteropAndAPINotes>
- <doc:MigratingFromSwiftBitcoin>

### Environments and Databases

- ``Environment``
- ``EnvironmentOptions``
- ``Database``
- ``DatabaseOptions``
- ``EnvironmentInfo``
- ``DatabaseStatistics``

### Transactions

- ``ReadTransaction``
- ``ResetReadTransaction``
- ``WriteTransaction``
- ``PutOptions``

### Cursors

- ``Cursor``
- ``ReadOnly``
- ``ReadWrite``
- ``CursorEntry``
- ``DuplicateBatch``

### Typed Keys and Values

- ``LMDBCodable``
- ``LMDBEncodable``
- ``LMDBDecodable``

### Errors and Version

- ``LMDBError``
- ``LMDBDecodingError``
- ``lmdbVersion``
- ``lmdbVersionString``
