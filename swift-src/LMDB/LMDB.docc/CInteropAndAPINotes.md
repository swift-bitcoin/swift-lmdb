# C Interop and API Notes

Learn how `CLMDBInterop` uses Clang API notes and `SafeInteropWrappers` to wrap `lmdb.h` without modifying upstream sources.

## Overview

All Swift interop annotations live in `swift-include/` alongside `swift-src/` and `swift-test/`, leaving `libraries/liblmdb/` and `Sources/CLMDB/` untouched:

```
swift-include/module.modulemap          CLMDBInterop: a second view of lmdb.h
swift-include/CLMDBInterop.apinotes     hand-written annotations for that view
swift-src/LMDB/                         the Swift wrapper (module LMDB)
swift-test/LMDBTests/                   Swift Testing suite
swift-test/CompileFailures/             code that must NOT compile
```

## A Separate Module So `CLMDB` Stays Pristine

Clang discovers API notes next to the `module.modulemap` that defines a module. Placing `.apinotes` beside `Sources/CLMDB/include/module.modulemap` would alter how `CLMDB` imports for existing downstream consumers.

Instead, `swift-include/module.modulemap` defines a second module, `CLMDBInterop`, over the same upstream `lmdb.h`. It is declared as a `.systemLibrary` target in `Package.swift` so it compiles no duplicate C objects. The `LMDB` target imports `CLMDBInterop` for its annotated declarations and depends on `CLMDB` to link the compiled library.

## The `counted_by: 1` Pattern for Out-Parameters

Most LMDB pointer parameters point to a single value rather than an array buffer: `MDB_env **`, `MDB_txn **`, `MDB_dbi *`, and `MDB_val *`. Annotating them as single-element bounded buffers with `NoEscape: true`:

```yaml
- Name: mdb_get
  Parameters:
  - Position: 2          # MDB_val *key
    NoEscape: true
    BoundsSafety: { Kind: counted_by, BoundedBy: 1 }
```

causes the Swift compiler's `@_SwiftifyImport` macro to generate a safe overload taking `inout MutableSpan<MDB_val>` (or `Span<MDB_val>` for `const` pointers), which the wrapper feeds from a stack-allocated `CollectionOfOne`:

```swift
var out = CollectionOfOne<MDB_txn?>(nil)
var outSpan = out.mutableSpan
try check(raw.beginTransaction(parent: nil, flags: flags, &outSpan))
return out[0]!
```

## Other API Notes Keys Used

| Key | Applied To | Effect |
|---|---|---|
| `SwiftImportAs: reference` + `immortal` retain/release | `MDB_env`, `MDB_txn`, `MDB_cursor` | Imported as foreign reference types rather than `OpaquePointer`, while lifetime remains explicitly owned by the `~Copyable` Swift wrappers. |
| `SwiftConformsTo: Swift.Sendable` | `MDB_env` | Environments can cross concurrency domains; transactions and cursors cannot. |
| `SwiftName` with `self:` | Wrapped C functions | Imported as methods on `MDB_env`, `MDB_txn`, and `MDB_cursor` (e.g. `env.beginTransaction(parent:flags:_:)`). |
| `EnumExtensibility: closed` + `Enumerators` | `MDB_cursor_op` | Imported as a `@frozen` Swift `enum` with cases `.first`, `.nextDuplicate`, `.setRange`, etc. |
| `Nullability` / `NullabilityOfRet` | Handles, `parent`, `name`, `mdb_strerror` | Replaces implicitly unwrapped optionals with explicit optionals or non-optional types. |
| `BoundsSafety: counted_by_or_null` | `mdb_del`'s `data` parameter | Generates `inout MutableSpan<MDB_val>?` so `nil` (`NULL`) can be passed to delete all values for a key. |
| `SwiftName: "getter:..."` | `mdb_env_get_maxkeysize` | Imported as the computed property `env.maxKeySize`. |
| `SwiftSafety: safe` | `MDB_val` | Allows constructing and storing `MDB_val` in `CollectionOfOne` without marking every mention `unsafe`; dereferencing `mv_data` (`UnsafeMutableRawPointer?`) remains `unsafe`. |

### Inspecting the Synthesized Interface

To inspect the Swift interface generated from `CLMDBInterop.apinotes`:

```sh
xcrun swift-synthesize-interface -module-name CLMDBInterop \
  -target arm64-apple-macos27.0 -I swift-include \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" | grep MutableSpan
```

## C Functions Not Wrapped, and Why

Of the 56 functions in `lmdb.h`, 42 are wrapped directly and 2 (`mdb_env_copy`, `mdb_env_copyfd`) are subsumed by their `*2` flag-accepting counterparts (``Environment/copy(to:compact:)`` and ``Environment/copy(toFileDescriptor:compact:)``). The remaining 12 are omitted intentionally:

| C Function | Why It Is Omitted |
|---|---|
| `mdb_cursor_renew` | Rebinds a cursor to a later read transaction, violating the compile-time guarantee that a ``Cursor`` cannot outlive the transaction it was opened from. Opening a fresh cursor in a read transaction is already cheap. |
| `mdb_dbi_close` | LMDB's own documentation notes that closing a database handle normally is unnecessary and doing so while another transaction uses it can corrupt data. Handles stay open until the ``Environment`` closes. |
| `mdb_set_compare`, `mdb_set_dupsort` | C function pointers with no user-context (`void *`) parameter, so they cannot capture a Swift closure and must operate on raw `MDB_val` pointers. Order-preserving ``LMDBEncodable`` encodings cover custom ordering safely. |
| `mdb_set_relfunc`, `mdb_set_relctx` | Unimplemented in LMDB itself (reserved for `MDB_FIXEDMAP` relocation). |
| `mdb_env_set_userctx`, `mdb_env_get_userctx` | Stores an untyped `void *` on `MDB_env`; in Swift, hold your state alongside ``Environment`` in your own type. |
| `mdb_env_set_assert` | A context-free C callback for internal LMDB assertions, which are compiled out unless LMDB is built with `MDB_DEBUG`. |
| `mdb_txn_env`, `mdb_cursor_txn`, `mdb_cursor_dbi` | Untyped C back-references; in Swift, the parent relationships are tracked statically by lifetime dependencies. |
