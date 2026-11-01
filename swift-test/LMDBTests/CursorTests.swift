import LMDB
import Testing

/// Fills a plain database with `keys`, each mapped to "value-<key>".
func fill(_ env: borrowing Environment, _ db: Database, keys: [String]) throws {
    try env.write { txn in
        for key in keys {
            try txn.put(bytes("value-\(key)").span.bytes, forKey: bytes(key).span.bytes, in: db)
        }
    }
}

/// Collects every key a cursor visits by repeatedly calling `step`.
func collectKeys(
    _ cursor: borrowing Cursor<ReadOnly>,
    _ step: (borrowing Cursor<ReadOnly>) throws -> [UInt8]?
) throws -> [String] {
    var keys: [String] = []
    while let key = try step(cursor) { keys.append(String(decoding: key, as: UTF8.self)) }
    return keys
}

/// A 4-byte big-endian encoding, so byte order matches numeric order.
func be32(_ n: UInt32) -> [UInt8] {
    [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
}

@Suite struct CursorTests {
    // MARK: Ordered iteration

    @Test func nextVisitsKeysInOrder() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["cherry", "apple", "banana"])

        let keys = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            return try collectKeys(cursor) { try $0.next()?.keyBytes }
        }
        #expect(keys == ["apple", "banana", "cherry"])
    }

    @Test func previousVisitsKeysInReverse() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["cherry", "apple", "banana"])

        let keys = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            return try collectKeys(cursor) { try $0.previous()?.keyBytes }
        }
        #expect(keys == ["cherry", "banana", "apple"])
    }

    @Test func firstLastAndCurrent() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["b", "a", "c"])

        let (first, last, current) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            let first = try cursor.first()?.keyBytes
            let last = try cursor.last()?.keyBytes
            let current = try cursor.current()?.valueBytes
            return (first, last, current)
        }
        #expect(first == bytes("a"))
        #expect(last == bytes("c"))
        #expect(current == bytes("value-c"))
    }

    @Test func emptyDatabaseHasNoEntries() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        let (first, next) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            return (try cursor.first() == nil, try cursor.next() == nil)
        }
        #expect(first)
        #expect(next)
    }

    /// Movement borrows the cursor, so entries from earlier positions stay
    /// usable: they point into the map, which moving does not change.
    @Test func entriesSurviveMovement() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["a", "b"])

        let (a, b) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            let a = try cursor.next()
            let b = try cursor.next()
            return (a?.keyBytes, b?.keyBytes)
        }
        #expect(a == bytes("a"))
        #expect(b == bytes("b"))
    }

    // MARK: Seeking

    @Test func seekToExactKey() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["a", "b", "c"])

        let (found, missing, afterSeek) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            let found = try cursor.seek(to: bytes("b").span.bytes)?.valueBytes
            let afterSeek = try cursor.next()?.keyBytes
            let missing = try cursor.seek(to: bytes("bb").span.bytes) == nil
            return (found, missing, afterSeek)
        }
        #expect(found == bytes("value-b"))
        #expect(afterSeek == bytes("c"))
        #expect(missing)
    }

    @Test func seekAtOrAfterForPrefixScan() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["apple", "apricot", "avocado", "banana", "ap"])

        let prefix = bytes("ap")
        let matches = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var matches: [String] = []
            var entry = try cursor.seek(atOrAfter: prefix.span.bytes)
            while let key = entry?.keyBytes, key.starts(with: prefix) {
                matches.append(String(decoding: key, as: UTF8.self))
                entry = try cursor.next()
            }
            return matches
        }
        #expect(matches == ["ap", "apple", "apricot"])
    }

    /// `seek(atOrAfter:)` returns the key from the map, not the probe passed
    /// in: the cursor re-reads with getCurrent after positioning.
    @Test func seekReturnsStoredKeyNotProbe() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["m"])

        let key = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            return try cursor.seek(atOrAfter: bytes("a").span.bytes)?.keyBytes
        }
        #expect(key == bytes("m"))
    }

    @Test func seekPastEndIsNil() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["a"])

        let none = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            return try cursor.seek(atOrAfter: bytes("z").span.bytes) == nil
        }
        #expect(none)
    }

    // MARK: Duplicate keys

    /// "fruit" → apple, banana, cherry; "veg" → kale, leek.
    func duplicates(_ env: borrowing Environment) throws -> Database {
        let db = try env.openDatabase(named: "dups", options: .duplicateSort)
        try env.write { txn in
            for (key, value) in [("fruit", "cherry"), ("veg", "leek"), ("fruit", "apple"),
                                 ("veg", "kale"), ("fruit", "banana")] {
                try txn.put(bytes(value).span.bytes, forKey: bytes(key).span.bytes, in: db)
            }
        }
        return db
    }

    @Test func nextVisitsEveryDuplicateInOrder() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try duplicates(env)

        let pairs = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var pairs: [String] = []
            while let entry = try cursor.next() {
                pairs.append("\(String(decoding: entry.keyBytes, as: UTF8.self))=\(String(decoding: entry.valueBytes, as: UTF8.self))")
            }
            return pairs
        }
        #expect(pairs == ["fruit=apple", "fruit=banana", "fruit=cherry", "veg=kale", "veg=leek"])
    }

    @Test func nextKeyAndPreviousKeySkipDuplicates() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try duplicates(env)

        let (forward, backward) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            let forward = try collectKeys(cursor) { try $0.nextKey()?.keyBytes }
            let backward = try collectKeys(cursor) { try $0.previousKey()?.keyBytes }
            return (forward, backward)
        }
        #expect(forward == ["fruit", "veg"])
        // Already on "veg", so going back reaches only "fruit".
        #expect(backward == ["fruit"])
    }

    @Test func walkingTheValuesOfOneKey() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try duplicates(env)

        let (count, first, last, values) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.seek(to: bytes("fruit").span.bytes)
            let count = try cursor.duplicateCount()
            let last = try cursor.lastDuplicate()?.valueBytes
            let first = try cursor.firstDuplicate()?.valueBytes
            var values: [String] = []
            while let entry = try cursor.nextDuplicate() {
                values.append(String(decoding: entry.valueBytes, as: UTF8.self))
            }
            return (count, first, last, values)
        }
        #expect(count == 3)
        #expect(first == bytes("apple"))
        #expect(last == bytes("cherry"))
        // nextDuplicate stops at the end of "fruit" rather than moving to "veg".
        #expect(values == ["banana", "cherry"])
    }

    @Test func previousDuplicate() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try duplicates(env)

        let values = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.seek(to: bytes("fruit").span.bytes)
            _ = try cursor.lastDuplicate()
            var values: [String] = []
            while let entry = try cursor.previousDuplicate() {
                values.append(String(decoding: entry.valueBytes, as: UTF8.self))
            }
            return values
        }
        #expect(values == ["banana", "apple"])
    }

    @Test func seekToKeyAndValue() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try duplicates(env)

        let (exact, missing, range) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            let exact = try cursor.seek(to: bytes("fruit").span.bytes, value: bytes("banana").span.bytes)?.valueBytes
            let missing = try cursor.seek(to: bytes("fruit").span.bytes, value: bytes("blueberry").span.bytes) == nil
            let range = try cursor.seek(to: bytes("fruit").span.bytes, valueAtOrAfter: bytes("blueberry").span.bytes)?.valueBytes
            return (exact, missing, range)
        }
        #expect(exact == bytes("banana"))
        #expect(missing)
        #expect(range == bytes("cherry"))
    }

    @Test func duplicateOpsNeedDuplicateSort() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["a"])

        let error = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.first()
            do throws(LMDBError) {
                _ = try cursor.duplicateCount()
                return nil as LMDBError?
            } catch {
                return error
            }
        }
        #expect(error != nil)
    }

    // MARK: Batches of fixed-size duplicates

    @Test func batchesReadEveryFixedSizeValue() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "fixed", options: [.duplicateSort, .duplicateFixed])
        // 5,000 four-byte values per key: more than one 16 KB page each.
        let numbers = (0..<10_000).map(UInt32.init)
        try env.write { txn in
            for n in numbers {
                try txn.put(be32(n).span.bytes, forKey: bytes(n.isMultiple(of: 2) ? "even" : "odd").span.bytes, in: db)
            }
        }

        func decode(_ batch: DuplicateBatch, into perKey: inout [String: [UInt32]]) {
            let key = String(decoding: batch.keyBytes, as: UTF8.self)
            let packed = batch.valuesBytes
            for i in stride(from: 0, to: packed.count, by: 4) {
                perKey[key, default: []].append(packed[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) })
            }
        }

        let (perKey, batchCount) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var perKey: [String: [UInt32]] = [:]
            var batchCount = 0
            var onKey = try cursor.first() != nil
            while onKey {
                if let batch = try cursor.duplicateBatch() {
                    decode(batch, into: &perKey)
                    batchCount += 1
                }
                while let batch = try cursor.nextDuplicateBatch() {
                    decode(batch, into: &perKey)
                    batchCount += 1
                }
                onKey = try cursor.nextKey() != nil
            }
            return (perKey, batchCount)
        }
        #expect(perKey["even"] == numbers.filter { $0.isMultiple(of: 2) })
        #expect(perKey["odd"] == numbers.filter { !$0.isMultiple(of: 2) })
        #expect(batchCount > 2)
    }

    @Test func nextDuplicateBatchDoesNotCrossKeys() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "fixed", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            for n: UInt32 in [1, 2] {
                try txn.put(be32(n).span.bytes, forKey: bytes("a").span.bytes, in: db)
            }
            try txn.put(be32(3).span.bytes, forKey: bytes("b").span.bytes, in: db)
        }

        let (first, next) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.first()
            let first = try cursor.duplicateBatch()?.valuesBytes
            return (first, try cursor.nextDuplicateBatch() == nil)
        }
        #expect(first == be32(1) + be32(2))
        #expect(next)
    }

    /// LMDB stores a lone value inline, and GET_MULTIPLE then succeeds without
    /// returning data; the wrapper must still produce the value.
    @Test func batchOfKeyWithSingleValue() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "fixed", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            try txn.put(be32(7).span.bytes, forKey: bytes("solo").span.bytes, in: db)
        }

        let (values, next) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.seek(to: bytes("solo").span.bytes)
            let values = try cursor.duplicateBatch()?.valuesBytes
            return (values, try cursor.nextDuplicateBatch() == nil)
        }
        #expect(values == be32(7))
        #expect(next)
    }

    @Test func duplicateBatchAtCurrentPosition() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "fixed", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            for n: UInt32 in [3, 1, 2] {
                try txn.put(be32(n).span.bytes, forKey: bytes("k").span.bytes, in: db)
            }
        }

        let packed = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.seek(to: bytes("k").span.bytes)
            return try cursor.duplicateBatch()?.valuesBytes
        }
        #expect(packed == be32(1) + be32(2) + be32(3))
    }

    // MARK: Writing through a cursor

    @Test func putThroughCursor() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        let positioned = try env.write { txn in
            var cursor = try Cursor(&txn, database: db)
            try cursor.put(bytes("v").span.bytes, forKey: bytes("k").span.bytes)
            return try cursor.current()?.keyBytes
        }
        let stored = try env.read { txn in try txn.bytes(forKey: bytes("k").span.bytes, in: db) }
        #expect(positioned == bytes("k"))
        #expect(stored == bytes("v"))
    }

    @Test func deleteWhileIterating() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["a1", "b1", "a2", "b2", "a3"])

        try env.write { txn in
            var cursor = try Cursor(&txn, database: db)
            // Copy the key out so no entry borrows the cursor during delete().
            while let key = try cursor.next()?.keyBytes {
                if key.first == UInt8(ascii: "a") { try cursor.delete() }
            }
        }
        let remaining = try env.read { txn in
            try collectKeys(try Cursor(txn, database: db)) { try $0.next()?.keyBytes }
        }
        #expect(remaining == ["b1", "b2"])
    }

    @Test func removeAllWhere() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try fill(env, db, keys: ["a1", "b1", "a2", "b2", "a3"])

        let removed = try env.write { txn in
            var cursor = try Cursor(&txn, database: db)
            return try cursor.removeAll { $0.keyBytes.first == UInt8(ascii: "a") }
        }
        let remaining = try env.read { txn in
            try collectKeys(try Cursor(txn, database: db)) { try $0.next()?.keyBytes }
        }
        #expect(removed == 3)
        #expect(remaining == ["b1", "b2"])
    }

    @Test func deleteAllDuplicatesOfAKey() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try duplicates(env)

        try env.write { txn in
            var cursor = try Cursor(&txn, database: db)
            _ = try cursor.seek(to: bytes("fruit").span.bytes)
            try cursor.deleteAllDuplicates()
        }
        let remaining = try env.read { txn in
            try collectKeys(try Cursor(txn, database: db)) { try $0.next()?.keyBytes }
        }
        #expect(remaining == ["veg", "veg"])
    }

    /// A read-only cursor may also be opened in a write transaction, which it
    /// borrows; the transaction's own writes are visible through it.
    @Test func readOnlyCursorInWriteTransaction() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        let keys = try env.write { txn in
            try txn.put(bytes("v").span.bytes, forKey: bytes("uncommitted").span.bytes, in: db)
            return try collectKeys(try Cursor(txn, database: db)) { try $0.next()?.keyBytes }
        }
        #expect(keys == ["uncommitted"])
    }

    /// Regression test for a use-after-free, meaningful under
    /// `swift test --sanitize=address`.
    ///
    /// The compiler accepts committing while a cursor on the transaction is
    /// still in scope, and runs the cursor's deinit after the commit, by which
    /// time LMDB has freed the cursor. Cursors in write transactions therefore
    /// leave closing to LMDB.
    @Test func cursorStillInScopeAtCommit() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        var txn = try WriteTransaction(env)
        var cursor = try Cursor(&txn, database: db)
        try cursor.put(bytes("v").span.bytes, forKey: bytes("k").span.bytes)
        try txn.commit()

        let stored = try env.read { txn in try txn.bytes(forKey: bytes("k").span.bytes, in: db) }
        #expect(stored == bytes("v"))
    }

    /// Many cursors in one write transaction: LMDB frees them all at commit.
    @Test func manyCursorsInOneWriteTransaction() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        try env.write { txn in
            for i in 0..<100 {
                var cursor = try Cursor(&txn, database: db)
                try cursor.put(bytes("v").span.bytes, forKey: bytes("k\(i)").span.bytes)
            }
        }
        let count = try env.read { txn in
            try collectKeys(try Cursor(txn, database: db)) { try $0.next()?.keyBytes }.count
        }
        #expect(count == 100)
    }
}
