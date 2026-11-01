import LMDB
import Testing

/// `ReadTransaction` / `WriteTransaction` used directly as non-escapable,
/// non-copyable values.
@Suite struct StandaloneTransactionTests {
    @Test func commitMakesChangesVisible() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        var write = try WriteTransaction(env)
        try write.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
        try write.commit()

        let read = try ReadTransaction(env)
        let stored = try read.bytes(forKey: key.span.bytes, in: db)
        #expect(stored == bytes("v"))
    }

    @Test func droppedWriteIsAborted() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        do {
            var write = try WriteTransaction(env)
            try write.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
            // Dropped here without commit(): deinit aborts.
        }
        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == nil)
    }

    @Test func explicitAbortDiscardsChanges() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        var write = try WriteTransaction(env)
        try write.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
        write.abort()

        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == nil)
    }

    /// The case closures cannot express: deciding whether to commit after
    /// inspecting what the transaction did.
    @Test func conditionalCommit() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        for (value, keep) in [("first", true), ("second", false)] {
            var write = try WriteTransaction(env)
            try write.put(bytes(value).span.bytes, forKey: key.span.bytes, in: db)
            if keep { try write.commit() } else { write.abort() }
        }
        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == bytes("first"))
    }

    /// A read transaction is a consistent snapshot: writes committed after it
    /// began are not visible through it.
    @Test func readTransactionIsASnapshot() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")
        try env.write { txn in try txn.put(bytes("old").span.bytes, forKey: key.span.bytes, in: db) }

        let snapshot = try ReadTransaction(env)
        try env.write { txn in try txn.put(bytes("new").span.bytes, forKey: key.span.bytes, in: db) }

        let seen = try snapshot.bytes(forKey: key.span.bytes, in: db)
        let latest = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(seen == bytes("old"))
        #expect(latest == bytes("new"))
    }

    @Test func spanFromStandaloneRead() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")
        try env.write { txn in try txn.put(bytes("value").span.bytes, forKey: key.span.bytes, in: db) }

        let read = try ReadTransaction(env)
        let span = try read.value(forKey: key.span.bytes, in: db)
        let count = span?.byteCount
        #expect(count == 5)
    }

    /// MDB_NOTLS lets a read transaction live across a suspension point.
    @Test func readTransactionAcrossAwait() async throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")
        try env.write { txn in
            try txn.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
        }

        let read = try ReadTransaction(env)
        await Task.yield()
        let stored = try read.bytes(forKey: key.span.bytes, in: db)
        #expect(stored == bytes("v"))
    }
}
