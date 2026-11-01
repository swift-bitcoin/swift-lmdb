import LMDB
import Testing

/// `Environment.read` / `Environment.write`: commit on return, abort on throw.
@Suite struct ClosureTransactionTests {
    @Test func putThenGet() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("alice")
        let value = bytes("hello")

        try env.write { txn in
            try txn.put(value.span.bytes, forKey: key.span.bytes, in: db)
        }
        let stored = try env.read { txn in
            try txn.bytes(forKey: key.span.bytes, in: db)
        }
        #expect(stored == value)
    }

    @Test func missingKeyIsNil() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let stored = try env.read { txn in
            try txn.bytes(forKey: bytes("absent").span.bytes, in: db)
        }
        #expect(stored == nil)
    }

    @Test func overwriteReplacesValue() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        try env.write { txn in
            try txn.put(bytes("one").span.bytes, forKey: key.span.bytes, in: db)
            try txn.put(bytes("two").span.bytes, forKey: key.span.bytes, in: db)
        }
        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == bytes("two"))
    }

    @Test func writeSeesItsOwnUncommittedData() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        let seen = try env.write { txn in
            try txn.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
            return try txn.bytes(forKey: key.span.bytes, in: db)
        }
        #expect(seen == bytes("v"))
    }

    @Test func throwingWriteIsRolledBack() throws {
        struct Bail: Error {}
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        #expect(throws: Bail.self) {
            try env.write { txn in
                try txn.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
                throw Bail()
            }
        }
        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == nil)
    }

    @Test func readsAreZeroCopySpans() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        try env.write { txn in
            try txn.put(bytes("value").span.bytes, forKey: key.span.bytes, in: db)
        }
        // `#expect` cannot capture a non-escapable span, so compute plain
        // values from it first.
        let count = try env.read { txn in
            try txn.value(forKey: key.span.bytes, in: db)?.byteCount
        }
        #expect(count == 5)
    }

    /// `write` is the way to write from async code: its closure is
    /// synchronous, so the writer lock never crosses a suspension point.
    @Test func writeFromAsyncContext() async throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let key = bytes("k")

        await Task.yield()
        try env.write { txn in
            try txn.put(bytes("v").span.bytes, forKey: key.span.bytes, in: db)
        }
        await Task.yield()
        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == bytes("v"))
    }
}
