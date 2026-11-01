# Cursors and Iteration

Traverse keys in order, run range and prefix scans, navigate duplicate values, and filter entries in place.

## Overview

A ``Cursor`` represents a position in a database's B-tree. Like transactions, cursors are `~Copyable` and `~Escapable`: their lifetime depends on the transaction they were opened from, so they cannot outlive that transaction.

```swift
try env.read { txn in
    let cursor = try Cursor(txn, database: db)

    while let entry = try cursor.next() {
        // Every entry, in key order
    }

    // Prefix scan
    var entry = try cursor.seek(atOrAfter: prefix)
    while let key = entry?.keyBytes, key.starts(with: prefix) {
        entry = try cursor.next()
    }
}

try env.write { txn in
    var cursor = try Cursor(&txn, database: db)      // `&`: read-write
    try cursor.removeAll { $0.keyBytes.first == 0 }
}
```

## Read-Only vs. Read-Write Cursors

`Cursor` is generic over a phantom access marker (``ReadOnly`` or ``ReadWrite``) so that every navigation method is defined once while write methods are restricted to mutable cursors:

- `Cursor(txn, database: db)` opens a `Cursor<ReadOnly>`, borrowing either a ``ReadTransaction`` or a ``WriteTransaction``. While a read-only cursor borrows a write transaction, the transaction cannot be mutated.
- `Cursor(&txn, database: db)` opens a `Cursor<ReadWrite>` with exclusive (`inout`) access to a ``WriteTransaction``, enabling ``Cursor/put(_:forKey:options:)-(RawSpan,RawSpan,_)``, ``Cursor/delete()``, ``Cursor/deleteAllDuplicates()``, and ``Cursor/removeAll(where:)``.

## Operations Summary

Every positioning method returns `nil` when there is no entry at the requested position (`MDB_NOTFOUND`), and throws ``LMDBError`` on failure:

| Group | Methods | Underlying LMDB Operation |
|---|---|---|
| Ordered traversal | ``Cursor/first()``, ``Cursor/last()``, ``Cursor/next()``, ``Cursor/previous()``, ``Cursor/current()`` | `MDB_FIRST`, `MDB_LAST`, `MDB_NEXT`, `MDB_PREV`, `MDB_GET_CURRENT` |
| Seeking | ``Cursor/seek(to:)-(RawSpan)``, ``Cursor/seek(atOrAfter:)-(RawSpan)`` | `MDB_SET`, `MDB_SET_RANGE` |
| Duplicates (``DatabaseOptions/duplicateSort``) | ``Cursor/nextKey()``, ``Cursor/previousKey()``, ``Cursor/firstDuplicate()``, ``Cursor/lastDuplicate()``, ``Cursor/nextDuplicate()``, ``Cursor/previousDuplicate()``, ``Cursor/seek(to:value:)-(RawSpan,RawSpan)``, ``Cursor/seek(to:valueAtOrAfter:)-(RawSpan,RawSpan)``, ``Cursor/duplicateCount()`` | `MDB_NEXT_NODUP`, `MDB_PREV_NODUP`, `MDB_FIRST_DUP`, `MDB_LAST_DUP`, `MDB_NEXT_DUP`, `MDB_PREV_DUP`, `MDB_GET_BOTH`, `MDB_GET_BOTH_RANGE`, `mdb_cursor_count` |
| Fixed-size batches (``DatabaseOptions/duplicateFixed``) | ``Cursor/duplicateBatch()``, ``Cursor/nextDuplicateBatch()``, ``Cursor/previousDuplicateBatch()`` | `MDB_GET_MULTIPLE`, `MDB_NEXT_MULTIPLE`, `MDB_PREV_MULTIPLE` |
| Writing (``ReadWrite`` only) | ``Cursor/put(_:forKey:options:)-(RawSpan,RawSpan,_)``, ``Cursor/delete()``, ``Cursor/deleteAllDuplicates()``, ``Cursor/removeAll(where:)`` | `mdb_cursor_put`, `mdb_cursor_del` |

Every seeking and writing method also has a typed overload accepting ``LMDBEncodable`` keys and values, and ``CursorEntry`` and ``DuplicateBatch`` decode directly to ``LMDBDecodable`` types via ``CursorEntry/key(as:)``, ``CursorEntry/value(as:)``, and ``DuplicateBatch/values(as:valueSize:)``.

## Cursor and Entry Lifetimes

- **Moving the cursor borrows `self`.** Stepping to another key or value does not invalidate previously read map pages in a read snapshot, so positioning methods are non-mutating and multiple ``CursorEntry`` values can be alive at the same time.
- **`put` and `delete` are `mutating`.** Modifying the database can reallocate pages and invalidate existing spans, so the compiler prevents calling `put` or `delete` while any ``CursorEntry`` or ``DuplicateBatch`` is still in use.
- **Bind the cursor to a local variable before reading from it.** Chaining directly off a temporary, such as `try Cursor(txn, database: db).last()?.value(as: Int.self)`, fails to compile because the returned ``CursorEntry`` borrows a temporary cursor whose lifetime ends before the expression completes.
- **`while let` bindings stay alive for the entire loop body.** Because `while let entry = try cursor.next()` keeps `entry` borrowing `cursor` throughout the loop body, calling `try cursor.delete()` inside that loop is rejected for overlapping access. Either copy out the bytes needed for the predicate (`while let key = try cursor.next()?.keyBytes`) or use ``Cursor/removeAll(where:)``.

## LMDB Quirks Smoothed Over by the Wrapper

- **Operations that take input do not always return pointers into the memory map.** For `MDB_SET` and `MDB_GET_BOTH`, LMDB leaves the key (and value) `MDB_val` pointing at the caller's temporary input buffer rather than the database's memory map, and duplicate operations do not always populate the key output. Returning those pointers as `RawSpan`s tied to the cursor's lifetime would dangle as soon as the input buffer went out of scope. Instead, every positioning operation follows up with `MDB_GET_CURRENT`, which always returns pointers into the memory map.
- **`MDB_GET_MULTIPLE` on a key with a single duplicate value.** When a key in a ``DatabaseOptions/duplicateFixed`` database has only one value, LMDB stores it inline rather than in a duplicate sub-page, and `MDB_GET_MULTIPLE` returns `MDB_SUCCESS` without filling in the data pointer. The wrapper falls back to the single value from `MDB_GET_CURRENT` so ``Cursor/duplicateBatch()`` never silently drops a lone value.
- **Batches never cross keys.** ``Cursor/nextDuplicateBatch()`` (`MDB_NEXT_MULTIPLE`) advances past the current page before reading and stops at the end of the current key. Always read the first page with ``Cursor/duplicateBatch()``, loop with ``Cursor/nextDuplicateBatch()`` until `nil`, and advance to the next key with ``Cursor/nextKey()``.
- **After ``Cursor/delete()``, ``Cursor/next()`` returns the immediately following entry.** LMDB marks the cursor as deleted so the next `MDB_NEXT` returns the element that shifted into place without skipping it.
