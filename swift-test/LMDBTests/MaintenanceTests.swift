import Foundation
import LMDB
import Testing

/// Statistics, environment info, syncing, copying and reader cleanup.
@Suite struct MaintenanceTests {
    // MARK: Statistics

    @Test func countAndStatistics() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "items")

        let uncommitted = try env.write { txn in
            for i in 0..<1_000 { try txn.put(i, forKey: i, in: db) }
            return try txn.count(in: db)
        }
        let (count, stats) = try env.read { txn in
            (try txn.count(in: db), try txn.statistics(for: db))
        }
        #expect(uncommitted == 1_000)
        #expect(count == 1_000)
        #expect(stats.entries == 1_000)
        #expect(stats.depth >= 2)   // 1,000 entries need more than one leaf page
        #expect(stats.leafPages > 1)
        #expect(stats.pageSize > 0)
        #expect(stats.totalPages == stats.branchPages + stats.leafPages + stats.overflowPages)
        #expect(try env.statistics(for: db) == stats)
    }

    @Test func duplicatesCountAsEntries() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: .duplicateSort)
        try env.write { txn in
            for value in ["a", "b", "c"] { try txn.put(value, forKey: "k", in: db) }
        }
        #expect(try env.statistics(for: db).entries == 3)
    }

    @Test func largeValuesUseOverflowPages() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put([UInt8](repeating: 1, count: 100_000), forKey: "big", in: db) }
        #expect(try env.statistics(for: db).overflowPages > 0)
    }

    /// The main database holds one entry per named database.
    @Test func mainDatabaseStatistics() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 3)
        for name in ["a", "b", "c"] { _ = try env.openDatabase(named: name) }
        #expect(try env.statistics.entries == 3)
    }

    @Test func databaseNames() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 3)
        for name in ["coins", "blocks", "headers"] { _ = try env.openDatabase(named: name) }
        #expect(try env.databaseNames() == ["blocks", "coins", "headers"])
    }

    // MARK: Environment info

    @Test func info() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxReaders: 9, mapSize: 8 * 1024 * 1024)
        let db = try env.openDatabase()
        let before = try env.info
        try env.write { txn in try txn.put(1, forKey: 1, in: db) }
        let after = try env.info

        #expect(before.mapSize == 8 * 1024 * 1024)
        #expect(before.maxReaders == 9)
        #expect(after.lastTransactionID == before.lastTransactionID + 1)
        #expect(after.lastPageNumber >= before.lastPageNumber)
    }

    @Test func path() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        #expect(try env.path == dir.path)
    }

    // MARK: Durability and backups

    @Test func sync() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, options: .noSync)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put(1, forKey: 1, in: db) }
        try env.sync()
        try env.sync(force: false)
    }

    @Test func copyToDirectory() throws {
        let dir = try TemporaryDirectory()
        let backup = try TemporaryDirectory()
        do {
            let env = try Environment(path: dir.path, maxDatabases: 1)
            let db = try env.openDatabase(named: "items")
            try env.write { txn in for i in 0..<100 { try txn.put("item \(i)", forKey: i, in: db) } }
            try env.copy(to: backup.path)
        }

        let copy = try Environment(path: backup.path, maxDatabases: 1)
        let db = try #require(try copy.existingDatabase(named: "items"))
        let (count, item) = try copy.read { txn in
            (try txn.count(in: db), try txn.value(forKey: 42, in: db, as: String.self))
        }
        #expect(count == 100)
        #expect(item == "item 42")
    }

    @Test func compactCopyIsSmaller() throws {
        let dir = try TemporaryDirectory()
        let plain = try TemporaryDirectory()
        let compacted = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        // Fill, then delete most of it, leaving free pages behind.
        try env.write { txn in
            for i in 0..<5_000 { try txn.put([UInt8](repeating: 7, count: 200), forKey: i, in: db) }
        }
        try env.write { txn in
            for i in 0..<4_900 { try txn.delete(forKey: i, in: db) }
        }

        try env.copy(to: plain.path)
        try env.copy(to: compacted.path, compact: true)

        func size(_ path: String) throws -> Int {
            try FileManager.default.attributesOfItem(atPath: path + "/data.mdb")[.size] as? Int ?? 0
        }
        #expect(try size(compacted.path) < size(plain.path))
        let remaining = try Environment(path: compacted.path).read { txn in
            try txn.count(in: try #require(try env.existingDatabase()))
        }
        #expect(remaining == 100)
    }

    @Test func copyOfSingleFileEnvironment() throws {
        let dir = try TemporaryDirectory()
        let source = dir.path + "/source.mdb"
        let target = dir.path + "/backup.mdb"
        let env = try Environment(path: source, options: .noSubdirectory)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put("v", forKey: "k", in: db) }
        try env.copy(to: target)

        let copy = try Environment(path: target, options: .noSubdirectory)
        let stored = try copy.read { txn in
            try txn.value(forKey: "k", in: try #require(try copy.existingDatabase()), as: String.self)
        }
        #expect(stored == "v")
    }

    @Test func copyToFileDescriptor() throws {
        let dir = try TemporaryDirectory()
        let target = dir.path + "/streamed.mdb"
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put("v", forKey: "k", in: db) }

        #expect(FileManager.default.createFile(atPath: target, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(filePath: target))
        try env.copy(toFileDescriptor: handle.fileDescriptor)
        try handle.close()

        let copy = try Environment(path: target, options: .noSubdirectory)
        let stored = try copy.read { txn in
            try txn.value(forKey: "k", in: try #require(try copy.existingDatabase()), as: String.self)
        }
        #expect(stored == "v")
    }

    // MARK: Transaction IDs and reuse

    @Test func transactionIDs() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let last = try env.info.lastTransactionID

        let readID = try env.read { txn in txn.id }
        let writeID = try env.write { txn in
            try txn.put(1, forKey: 1, in: db)
            return txn.id
        }
        #expect(readID == last)
        #expect(writeID == last + 1)
        #expect(try env.info.lastTransactionID == writeID)
    }

    /// A reset transaction renews onto the latest snapshot.
    @Test func resetAndRenew() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put("old", forKey: "k", in: db) }

        var txn = try ReadTransaction(env)
        let before = try txn.value(forKey: "k", in: db, as: String.self)
        let firstID = txn.id

        let reset = txn.reset()
        try env.write { txn in try txn.put("new", forKey: "k", in: db) }
        txn = try reset.renew()

        let after = try txn.value(forKey: "k", in: db, as: String.self)
        #expect(before == "old")
        #expect(after == "new")
        #expect(txn.id == firstID + 1)
    }

    @Test func renewRepeatedly() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()

        var txn = try ReadTransaction(env)
        for i in 0..<100 {
            let reset = txn.reset()
            try env.write { txn in try txn.put(i, forKey: "counter", in: db) }
            txn = try reset.renew()
            #expect(try txn.value(forKey: "counter", in: db, as: Int.self) == i)
        }
    }

    // MARK: Comparing in a database's order

    @Test func compareKeysUsesTheDatabaseOrder() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let plain = try env.openDatabase()
        let reversed = try env.openDatabase(named: "reversed", options: .reverseKey)

        let (forward, backward, typed, same) = try env.read { txn in
            (try txn.compareKeys("ab", "ba", in: plain),
             try txn.compareKeys("ab", "ba", in: reversed),
             try txn.compareKeys(-5, 3, in: plain),
             try txn.compareKeys("x", "x", in: plain))
        }
        #expect(forward == .orderedAscending)
        #expect(backward == .orderedDescending)   // compared from the last byte: "b" > "a"
        #expect(typed == .orderedAscending)       // the sign-flipped encoding sorts -5 first
        #expect(same == .orderedSame)
    }

    @Test func compareValuesInDuplicateSortDatabase() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 2)
        let dups = try env.openDatabase(named: "dups", options: [.duplicateSort, .reverseDuplicate])
        let plain = try env.openDatabase(named: "plain")

        let order = try env.read { txn in try txn.compareValues("ab", "ba", in: dups) }
        #expect(order == .orderedDescending)
        // LMDB has no value comparator for this database: mdb_dcmp would call NULL.
        #expect(throws: LMDBError.incompatible) {
            try env.read { txn in try txn.compareValues("a", "b", in: plain) }
        }
    }

    @Test func integerKeyComparisonsAreNumericAndSizeChecked() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "ints", options: .integerKey)
        // Native-endian (little-endian here) UInt32 1 and 256: bytewise, 256
        // would sort first.
        let one: [UInt8] = [1, 0, 0, 0]
        let twoFiftySix: [UInt8] = [0, 1, 0, 0]

        let order = try env.read { txn in try txn.compareKeys(one.span.bytes, twoFiftySix.span.bytes, in: db) }
        #expect(order == .orderedAscending)
        // Different sizes would make LMDB read past the shorter key.
        #expect(throws: LMDBError.badValueSize) {
            try env.read { txn in
                try txn.compareKeys(one.span.bytes, [UInt8]([1, 0]).span.bytes, in: db)
            }
        }
    }

    // MARK: Introspection

    @Test func fileDescriptor() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        #expect(try env.fileDescriptor >= 0)
    }

    @Test func readerList() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)

        let idle = try env.readerList()
        let busy = try env.read { _ in try env.readerList() }
        let pid = String(ProcessInfo.processInfo.processIdentifier)

        #expect(idle == ["(no active readers)"])
        #expect(busy.first?.contains("pid") == true)
        #expect(busy.dropFirst().contains { $0.split(separator: " ").first.map(String.init) == pid })
    }

    // MARK: Readers

    @Test func noStaleReadersInAHealthyProcess() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        try env.read { _ in }
        #expect(try env.clearStaleReaders() == 0)
    }
}
