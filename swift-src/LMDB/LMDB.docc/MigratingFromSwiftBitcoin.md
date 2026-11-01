# Migrating from swift-bitcoin's Wrapper

Map types, methods, and idioms from `swift-bitcoin`'s `src/lmdb` wrapper to `LMDB`.

## API Mapping

| `swift-bitcoin` (`src/lmdb`) | `LMDB` |
|---|---|
| `Environment(at: url, maxDBs:, maxReaders:, pages:, options:)` | `Environment(path: url.path, options:, maxDatabases:, maxReaders:, mapSize: pages * pageSize)` |
| `Database.Descriptor("by-id")`, opened inside every transaction | ``Environment/openDatabase(named:options:)`` once at startup, then pass the ``Database`` handle to any transaction |
| `.create` in `Database.Options` | ``Environment/openDatabase(named:options:)`` creates; ``Environment/existingDatabase(named:options:)`` does not |
| `env.withTransaction(db: a, b, options: .readOnly) { _, a, b in }` | ``Environment/read(_:)`` with any number of databases |
| `env.withTransaction(db: a) { _, a in }` | ``Environment/write(_:)`` |
| `db.get(key) -> Data?`, `db.put(data, key:)`, `db.delete(key) -> Bool` | ``ReadTransaction/value(forKey:in:as:)``, ``WriteTransaction/put(_:forKey:in:options:)-(LMDBEncodable,LMDBEncodable,_,_)``, ``WriteTransaction/delete(forKey:in:)-(LMDBEncodable,_)`` (typed or `RawSpan`, zero-copy) |
| `db.count`, `db.stats` | ``ReadTransaction/count(in:)``, ``ReadTransaction/statistics(for:)`` |
| `db.empty()`, `db.drop(delete: true)` | ``WriteTransaction/removeAll(in:)``, ``WriteTransaction/dropDatabase(_:)`` |
| `db.first`, `db.last` | Open a ``Cursor`` and call ``Cursor/first()`` / ``Cursor/last()`` |
| `db.removeFirst()` | Open a read-write ``Cursor`` (`Cursor(&txn, database:)`) and call ``Cursor/first()`` then ``Cursor/delete()`` |
| `db.withCursor { cursor in cursor.get(.nextDup) }` | `let cursor = try Cursor(txn, database:)`; `try cursor.nextDuplicate()` |
| `cursor.getPair(op) -> (Data, Data)?` | ``CursorEntry`` with ``CursorEntry/key`` / ``CursorEntry/value`` spans and ``CursorEntry/key(as:)`` / ``CursorEntry/value(as:)`` |
| `cursor.set(key:)` then `cursor.get(.firstDup)` | ``Cursor/seek(to:)-(RawSpan)`` (returns the first entry directly) |
| `cursor.get(.getMultiple) -> Data?` | ``Cursor/duplicateBatch()`` returning ``DuplicateBatch`` |
| `env.copy(options: .compact)` | ``Environment/copy(to:compact:)`` |
| `env.drop()` (a sync) | ``Environment/sync(force:)`` |
| `LMDBVersion.current` | ``lmdbVersion``, ``lmdbVersionString`` |
| `Transaction.InitError<E>`, `Database.AccessError` | ``LMDBError`` plus your own domain errors |
| `.integerKey` with native-endian `Int` heights | `Int` keys without `.integerKey` (see <doc:TypedKeysAndValues>) |

## Common Idioms

### Reading the First or Last Entry (`db.first` / `db.last`)

Open a read-only ``Cursor`` and decode the key or value directly:

```swift
let (first, last) = try env.read { txn in
    let cursor = try Cursor(txn, database: db)
    return (try cursor.first()?.valueBytes, try cursor.last()?.valueBytes)
}

let newestHeight = try env.read { txn in
    let cursor = try Cursor(txn, database: byHeight)
    return try cursor.last()?.key(as: Int.self)
}
```

### Removing the First Entry (`db.removeFirst()`)

Use a read-write ``Cursor``:

```swift
let removed = try env.write { txn in
    var cursor = try Cursor(&txn, database: db)
    guard try cursor.first() != nil else { return false }
    try cursor.delete()
    return true
}
```

### Storing `Environment` and `Database` Handles Together

Instead of reopening `Database.Descriptor` on every transaction, open each ``Database`` once when initializing your storage type and keep the `Sendable` handles next to the ``Environment``:

```swift
struct BlockIndexStorage: ~Copyable {
    let env: Environment
    let byID: Database
    let byHeight: Database

    init(path: String, pageSize: Int) throws {
        // Perform all throwing calls into locals before assigning stored properties:
        // a ~Copyable struct cannot be left partially initialized on a throwing path.
        let env = try Environment(
            path: path,
            options: .noSubdirectory,
            maxDatabases: 2,
            mapSize: 50_000 * pageSize
        )
        let byID = try env.openDatabase(named: "by-id")
        let byHeight = try env.openDatabase(
            named: "by-height",
            options: [.duplicateSort, .duplicateFixed]
        )
        self.env = env
        self.byID = byID
        self.byHeight = byHeight
    }
}
```

> Important: In a `~Copyable` struct initializer, assigning *any* stored property (even a copyable one like `byID`) before a subsequent `try` fails with `conditional initialization or destruction of noncopyable types is not supported`. Opening into local constants first and assigning at the end avoids partial initialization.

### Multi-Database Transactions

Because ``Database`` handles live on your storage struct, a single ``Environment/read(_:)`` or ``Environment/write(_:)`` closure can read or write any number of databases without variadic `withTransaction(db:)` overloads:

```swift
try storage.env.write { txn in
    try txn.put(id, forKey: id, in: storage.byID)
    try txn.put(id, forKey: height, in: storage.byHeight)
}
```
