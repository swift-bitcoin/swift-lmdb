# Compile-Time Safety and Lifetimes

Understand how `~Copyable`, `~Escapable`, lifetime dependencies, and strict memory safety prevent LMDB misuse at compile time.

## Overview

LMDB is fast because reads return pointers directly into the memory-mapped database file, with no allocation or copying. In C, keeping those pointers safe is up to the caller: a pointer becomes invalid when its transaction ends, when a cursor closes, or when a subsequent write in the same transaction reallocates pages.

This wrapper encodes those rules using Swift's non-copyable (`~Copyable`) and non-escapable (`~Escapable`) types, lifetime annotations (`@_lifetime`), and `.strictMemorySafety()`.

## What the Compiler Enforces

Each of the following misuses fails to compile. Every row is backed by a sample in `swift-test/CompileFailures/`:

| Misuse | Rejected because | Diagnostic |
|---|---|---|
| A transaction outliving its environment | `@_lifetime(borrow environment)` on the initializers | `lifetime-dependent value escapes its scope` |
| Closing (consuming) the environment while a transaction is open | The same borrow dependency | `noncopyable 'env' cannot be consumed when ... borrowed by a non-Escapable type` |
| Storing a transaction in a class or global | `~Escapable` | `lifetime-dependent variable ... escapes its scope` |
| Using a transaction after ``WriteTransaction/commit()`` | `~Copyable` + `consuming` | `'txn' used after consume` |
| A value span outliving its transaction | `@_lifetime(borrow self)` on ``ReadTransaction/value(forKey:in:)-(RawSpan,_)`` | `... requires that 'RawSpan' conform to 'Escapable'` |
| `put` while a span from an earlier read is alive (LMDB invalidates it) | Reads borrow, `put` is `mutating` | `overlapping accesses to 'txn', but modification requires exclusive access` |
| Opening a ``WriteTransaction`` in `async` code | `@available(*, noasync)` | `initializer 'init' is unavailable from asynchronous contexts` |
| A cursor outliving its transaction | `@_lifetime` on the cursor initializers | `lifetime-dependent value escapes its scope` |
| A cursor entry outliving its cursor | `@_lifetime(borrow self)` on every positioning method | `... requires that 'CursorEntry' conform to 'Escapable'` |
| Committing while a read-only cursor still borrows the transaction | The borrow dependency | `... borrowed by a non-Escapable type` |
| Writing through the transaction while a read-only cursor is open | The cursor borrows the transaction, `put` is `mutating` | `overlapping accesses to 'txn'` |
| Reading through the transaction while a read-write cursor is open | `Cursor(&txn, ...)` holds exclusive access | `overlapping accesses to 'txn'` |
| ``Cursor/delete()`` while an entry from the cursor is alive | Entries borrow the cursor, `delete` is `mutating` | `overlapping accesses to 'cursor'` |
| ``Cursor/delete()`` / `put` on a read-only cursor | Only `Cursor<ReadWrite>` has them | `... 'ReadOnly' and 'ReadWrite' be equivalent` |
| ``Environment/setMapSize(_:)`` while a transaction is open (LMDB forbids it) | Transactions borrow the environment, `setMapSize` is `mutating` | `overlapping accesses to 'env'` |
| Using a parent transaction inside ``WriteTransaction/nested(_:)`` (LMDB forbids it) | The child holds the parent exclusively | `overlapping accesses to 'txn'` |
| ``ReadTransaction/reset()`` while a span or cursor from the snapshot is alive | `reset()` is `consuming` | `... borrowed by a non-Escapable type` |
| A reset transaction outliving its environment | `@_lifetime(copy self)` keeps the environment dependency | `lifetime-dependent value escapes its scope` |

## Threads and `async`

LMDB ties two things to OS threads, and the wrapper handles each:

- **Read transactions** are thread-bound by default in C. The wrapper always opens environments with `MDB_NOTLS`, so a ``ReadTransaction`` belongs to its Swift value rather than thread-local storage and may be held across an `await`. It is still not `Sendable`, since LMDB allows only one thread to use a transaction at a time.
- **The writer lock** is owned by the OS thread that acquired it, and `MDB_NOTLS` does not change that. A write transaction held across an `await` could resume and commit on a different thread, so ``WriteTransaction/init(_:)`` is marked `@available(*, noasync)`. From `async` code, use ``Environment/write(_:)``, whose closure is synchronous.

> Note: Beginning a second write transaction on a thread that already holds one deadlocks, just as it does in C. Preventing that statically would require making ``WriteTransaction/init(_:)`` take the environment `inout`, which would also block concurrent reads during a write and make an environment impossible to share without wrapping it.

## Closures or Standalone Transactions?

Both styles are equally memory-safe. The difference is ergonomics:

- **Prefer ``Environment/read(_:)`` and ``Environment/write(_:)`` by default:**
  - `write` automatically commits when its closure returns and aborts when it throws. A standalone ``WriteTransaction`` that you forget to ``WriteTransaction/commit()`` is silently aborted when it goes out of scope, because the compiler cannot require a non-copyable value to be consumed by a specific method.
  - `write` works from `async` code because its closure is synchronous, ensuring the writer lock never crosses an `await`.
  - The transaction scope is visually explicit and short. Long-lived read transactions pin old pages and cause the database file to grow under write load.
- **Use ``ReadTransaction`` and ``WriteTransaction`` directly when the scope isn't a single block:**
  - Deciding whether to commit or abort after inspecting the result of several writes.
  - Passing a transaction across helper functions.
  - Holding a read snapshot across an `await`, or resetting and renewing it with ``ReadTransaction/reset()`` and ``ResetReadTransaction/renew()``.

## Why Nested Transactions and Write-Transaction Cursors Are Handled Carefully

Consider a read-write cursor opened `inout` on a standalone write transaction:

```swift
var txn = try WriteTransaction(env)
var cursor = try Cursor(&txn, database: db)
try cursor.put(value, forKey: key)
try txn.commit()        // accepted, but cursor's deinit runs *after* this
```

The cursor's lifetime dependency on `&txn` ends at its last use (`cursor.put`), so the compiler allows `txn.commit()`. However, `cursor`'s `deinit` still runs at the end of the lexical scope—*after* LMDB has already freed the write transaction's cursors during `mdb_txn_commit`. Calling `mdb_cursor_close` in `deinit` there would be a heap use-after-free.

The wrapper avoids this in two ways:

1. **Cursors in write transactions are not closed by `deinit`.** LMDB tracks all cursors opened in a write transaction and closes/frees them automatically when the transaction commits or aborts. Cursors in read transactions are not tracked by LMDB, and LMDB documents that `mdb_cursor_close` may be called before or after a read transaction ends, so `deinit` closes them as usual.
2. **Nested transactions (``WriteTransaction/nested(_:)``) are closure-only.** A standalone child transaction would depend on `&parent` in the exact same way, and unlike cursors, an uncommitted child transaction *must* be aborted in `deinit` (`mdb_txn_abort`), which would touch freed memory if the parent committed first. Inside ``WriteTransaction/nested(_:)``, the child always finishes before the method returns.

## Where `unsafe` Remains

The wrapper builds with zero warnings under `.strictMemorySafety()`, with `.treatWarning("StrictMemorySafety", as: .error)` enabled in `Package.swift`. The remaining `unsafe` sites are confined to the boundary with C pointers:

- **`RawSpan` → `MDB_val`** (`withMDBVal`): handing LMDB a pointer to Swift-owned bytes. Clang bounds annotations cannot describe a pointer stored *inside* a C struct (`MDB_val`).
- **`MDB_val` → `RawSpan`** (`mapSpan()`) in `get` and cursor operations, paired with `_overrideLifetime` to tie the span's lifetime to the borrowing transaction or cursor.
- **Cursor and transaction lifetime bindings**: `_overrideLifetime` attaches the borrow or `inout` dependency on the parent transaction or environment, since the imported C handle carries none.
- **C strings** passed to `mdb_env_open`, `mdb_dbi_open`, and `mdb_env_copy2`, and returned from `mdb_strerror`, `mdb_version`, `mdb_env_get_path`, and `mdb_reader_list`.
- **`MDB_RESERVE`**: wrapping LMDB's reserved write buffer (`mv_data`, `mv_size`) in an `OutputRawSpan`.
- **Internal span helpers** in `Polyfills.swift` (`OutputRawSpan.append(contentsOf:)`, `Data(RawSpan)`, and `[UInt8](RawSpan)`).
