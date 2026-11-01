import LMDB
import Testing

/// Deleting, put options, MDB_RESERVE, dropping and nested transactions.
@Suite struct WriteOperationTests {
    // MARK: Deleting

    @Test func deleteByKey() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        let (existed, missing) = try env.write { txn in
            try txn.put(bytes("v").span.bytes, forKey: bytes("k").span.bytes, in: db)
            let existed = try txn.delete(forKey: bytes("k").span.bytes, in: db)
            let missing = try txn.delete(forKey: bytes("k").span.bytes, in: db)
            return (existed, missing)
        }
        let stored = try env.read { txn in try txn.bytes(forKey: bytes("k").span.bytes, in: db) }
        #expect(existed)
        #expect(!missing)
        #expect(stored == nil)
    }

    @Test func deleteOneDuplicateOrAll() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: .duplicateSort)

        let (one, absent, values) = try env.write { txn in
            for v in ["a", "b", "c"] { try txn.put(v, forKey: "k", in: db) }
            let one = try txn.delete("b", forKey: "k", in: db)
            let absent = try txn.delete("zz", forKey: "k", in: db)
            var values: [String] = []
            let cursor = try Cursor(txn, database: db)
            while let entry = try cursor.next() { values.append(try entry.value(as: String.self)) }
            return (one, absent, values)
        }
        #expect(one)
        #expect(!absent)
        #expect(values == ["a", "c"])

        let all = try env.write { txn in try txn.delete(forKey: "k", in: db) }
        let left = try env.read { txn in try txn.value(forKey: "k", in: db, as: String.self) }
        #expect(all)
        #expect(left == nil)
    }

    // MARK: Put options

    @Test func noOverwriteThrowsKeyExists() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        #expect(throws: LMDBError.keyExists) {
            try env.write { txn in
                try txn.put("first", forKey: "k", in: db)
                try txn.put("second", forKey: "k", in: db, options: .noOverwrite)
            }
        }
    }

    @Test func insertOnlyStoresNewKeys() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        let (first, second) = try env.write { txn in
            (try txn.insert("first", forKey: "k", in: db), try txn.insert("second", forKey: "k", in: db))
        }
        let stored = try env.read { txn in try txn.value(forKey: "k", in: db, as: String.self) }
        #expect(first)
        #expect(!second)
        #expect(stored == "first")
    }

    @Test func noDuplicateData() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: .duplicateSort)

        try env.write { txn in
            try txn.put("a", forKey: "k", in: db, options: .noDuplicateData)
            try txn.put("b", forKey: "k", in: db, options: .noDuplicateData)
        }
        #expect(throws: LMDBError.keyExists) {
            try env.write { txn in try txn.put("a", forKey: "k", in: db, options: .noDuplicateData) }
        }
    }

    @Test func appendLoadsSortedKeys() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        try env.write { txn in
            for i in 0..<1_000 { try txn.put(i * 2, forKey: i, in: db, options: .append) }
        }
        let (count, last) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var count = 0
            while try cursor.next() != nil { count += 1 }
            return (count, try cursor.last()?.value(as: Int.self))
        }
        #expect(count == 1_000)
        #expect(last == 1_998)

        #expect(throws: LMDBError.keyExists) {
            try env.write { txn in try txn.put(0, forKey: 5, in: db, options: .append) }
        }
    }

    @Test func appendDuplicate() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: .duplicateSort)

        try env.write { txn in
            for v: UInt32 in [1, 2, 3] { try txn.put(v, forKey: "k", in: db, options: .appendDuplicate) }
        }
        #expect(throws: LMDBError.keyExists) {
            try env.write { txn in try txn.put(UInt32(0), forKey: "k", in: db, options: .appendDuplicate) }
        }
    }

    // MARK: MDB_RESERVE

    @Test func reserveWritesInPlace() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        try env.write { txn in
            try txn.put(reservingByteCount: 6, forKey: "k", in: db) { output in
                output.append(UInt32(0x0102_0304), as: UInt32.self, .bigEndian)
                output.append(5)
                output.append(6)
            }
        }
        let stored = try env.read { txn in try txn.value(forKey: "k", in: db, as: [UInt8].self) }
        #expect(stored == [1, 2, 3, 4, 5, 6])
    }

    @Test func reserveIsRejectedForDuplicateSort() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: .duplicateSort)

        #expect(throws: LMDBError.incompatible) {
            try env.write { txn in
                try txn.put(reservingByteCount: 1, forKey: "k", in: db) { $0.append(1) }
            }
        }
    }

#if os(macOS) || os(Linux)
// exit test code here
    @Test func reserveTrapsWhenUnderWritten() async {
        await #expect(processExitsWith: .failure) {
            let dir = try TemporaryDirectory()
            let env = try Environment(path: dir.path)
            let db = try env.openDatabase()
            try env.write { txn in
                try txn.put(reservingByteCount: 4, forKey: "k", in: db) { $0.append(1) }
            }
        }
    }
#endif

    // MARK: Emptying and dropping

    @Test func removeAllKeepsTheDatabase() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "items")
        try env.write { txn in for i in 0..<10 { try txn.put(i, forKey: i, in: db) } }

        try env.write { txn in try txn.removeAll(in: db) }
        let empty = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            return try cursor.first() == nil
        }
        let stillThere = try env.existingDatabase(named: "items") != nil
        #expect(empty)
        #expect(stillThere)
    }

    @Test func dropDatabaseDeletesIt() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "items")
        try env.write { txn in try txn.put(1, forKey: 1, in: db) }

        try env.write { txn in try txn.dropDatabase(db) }
        #expect(try env.existingDatabase(named: "items") == nil)
        #expect(throws: LMDBError.self) {
            try env.read { txn in try txn.value(forKey: 1, in: db, as: Int.self) }
        }
    }

    // MARK: Nested transactions

    @Test func nestedCommitsIntoParent() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        let seenByParent = try env.write { txn in
            try txn.put("parent", forKey: "p", in: db)
            let seenByChild = try txn.nested { child in
                try child.put("child", forKey: "c", in: db)
                return try child.value(forKey: "p", in: db, as: String.self)
            }
            #expect(seenByChild == "parent")
            return try txn.value(forKey: "c", in: db, as: String.self)
        }
        let stored = try env.read { txn in try txn.value(forKey: "c", in: db, as: String.self) }
        #expect(seenByParent == "child")
        #expect(stored == "child")
    }

    @Test func throwingNestedIsDiscarded() throws {
        struct Bail: Error {}
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        try env.write { txn in
            try txn.put("kept", forKey: "p", in: db)
            #expect(throws: Bail.self) {
                try txn.nested { child in
                    try child.put("discarded", forKey: "c", in: db)
                    throw Bail()
                }
            }
        }
        let (parent, child) = try env.read { txn in
            (try txn.value(forKey: "p", in: db, as: String.self),
             try txn.value(forKey: "c", in: db, as: String.self))
        }
        #expect(parent == "kept")
        #expect(child == nil)
    }

    @Test func nestedTwoLevels() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        try env.write { txn in
            try txn.nested { child in
                try child.nested { grandchild in try grandchild.put(3, forKey: "depth", in: db) }
            }
        }
        let depth = try env.read { txn in try txn.value(forKey: "depth", in: db, as: Int.self) }
        #expect(depth == 3)
    }

    /// A committed child is still part of its parent: aborting the parent
    /// discards it too.
    @Test func abortingParentDiscardsCommittedChild() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        var txn = try WriteTransaction(env)
        try txn.nested { child in try child.put("v", forKey: "k", in: db) }
        txn.abort()

        let stored = try env.read { txn in try txn.value(forKey: "k", in: db, as: String.self) }
        #expect(stored == nil)
    }
}
