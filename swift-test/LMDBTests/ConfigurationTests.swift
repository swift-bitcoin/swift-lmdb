import Foundation
import LMDB
import Testing

/// Environment options, limits, map resizing and opening databases.
@Suite struct ConfigurationTests {
    @Test func optionsAreReportedAndChangeable() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, options: [.noSync, .noReadAhead])

        let initial = try env.options
        try env.setOptions(.noSync, enabled: false)
        try env.setOptions(.noMetaSync, enabled: true)
        let changed = try env.options

        #expect(initial == [.noSync, .noReadAhead])
        #expect(changed == [.noMetaSync, .noReadAhead])
    }

    @Test func onlyChangeableOptionsCanChange() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        #expect(throws: LMDBError.self) { try env.setOptions(.readOnly, enabled: true) }
    }

    @Test func readOnlyEnvironment() throws {
        let dir = try TemporaryDirectory()
        do {
            let env = try Environment(path: dir.path, maxDatabases: 1)
            let db = try env.openDatabase(named: "items")
            try env.write { txn in try txn.put("v", forKey: "k", in: db) }
        }

        let env = try Environment(path: dir.path, options: .readOnly, maxDatabases: 1)
        let db = try #require(try env.existingDatabase(named: "items"))
        let stored = try env.read { txn in try txn.value(forKey: "k", in: db, as: String.self) }
        #expect(stored == "v")
        #expect(throws: LMDBError.self) { try env.write { txn in try txn.put("w", forKey: "k", in: db) } }
        #expect(throws: LMDBError.self) { try env.openDatabase(named: "new") }
    }

    /// `mdb_dbi_open` must not run in concurrent transactions. Meaningful
    /// under `swift test --sanitize=thread`.
    @Test func concurrentDatabaseOpensOnReadOnlyEnvironment() async throws {
        final class Shared: Sendable {
            let env: Environment
            init(_ env: consuming Environment) { self.env = env }
        }
        let dir = try TemporaryDirectory()
        let names = (0..<8).map { "db\($0)" }
        do {
            let env = try Environment(path: dir.path, maxDatabases: 8)
            for name in names { _ = try env.openDatabase(named: name) }
        }
        let shared = Shared(try Environment(path: dir.path, options: .readOnly, maxDatabases: 8))

        let opened = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<64 {
                group.addTask { try shared.env.existingDatabase(named: names[i % names.count]) != nil }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(opened == 64)
    }

    @Test func concurrentOptionChanges() async throws {
        final class Shared: Sendable {
            let env: Environment
            init(_ env: consuming Environment) { self.env = env }
        }
        let dir = try TemporaryDirectory()
        let shared = Shared(try Environment(path: dir.path))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask { try shared.env.setOptions(.noSync, enabled: i.isMultiple(of: 2)) }
            }
            try await group.waitForAll()
        }
    }

    @Test func noSubdirectoryUsesAFile() throws {
        let dir = try TemporaryDirectory()
        let file = dir.path + "/single.mdb"
        let env = try Environment(path: file, options: .noSubdirectory)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put(1, forKey: 1, in: db) }

        let type = try FileManager.default.attributesOfItem(atPath: file)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(FileManager.default.fileExists(atPath: file + "-lock"))
    }

    @Test func fileModeIsApplied() throws {
        let dir = try TemporaryDirectory()
        _ = try Environment(path: dir.path, fileMode: 0o600)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.path + "/data.mdb")
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func maxReaders() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxReaders: 7)
        #expect(try env.maxReaders == 7)
    }

    /// The limit depends on how LMDB was built and on the page size, so test
    /// what it means rather than its value.
    @Test func maxKeySizeIsTheLongestAcceptedKey() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let limit = env.maxKeySize

        try env.write { txn in
            try txn.put(1, forKey: [UInt8](repeating: 1, count: limit), in: db)
        }
        #expect(throws: LMDBError.badValueSize) {
            try env.write { txn in
                try txn.put(1, forKey: [UInt8](repeating: 1, count: limit + 1), in: db)
            }
        }
    }

    @Test func growingTheMapAfterMapFull() throws {
        let dir = try TemporaryDirectory()
        var env = try Environment(path: dir.path, mapSize: 64 * 1024)
        let db = try env.openDatabase()
        let big = [UInt8](repeating: 7, count: 256 * 1024)

        #expect(throws: LMDBError.mapFull) {
            try env.write { txn in try txn.put(big, forKey: "big", in: db) }
        }
        try env.setMapSize(4 * 1024 * 1024)
        try env.write { txn in try txn.put(big, forKey: "big", in: db) }
        let count = try env.read { txn in try txn.value(forKey: "big", in: db)?.byteCount }
        #expect(count == big.count)
    }

    @Test func existingDatabaseIsNilWhenMissing() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        #expect(try env.existingDatabase(named: "nope") == nil)
    }

    /// The handle reports the options the database was created with, not the
    /// ones passed when reopening it.
    @Test func databaseReportsStoredOptions() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let created = try env.openDatabase(named: "dups", options: [.duplicateSort, .duplicateFixed])
        let reopened = try #require(try env.existingDatabase(named: "dups"))
        #expect(created.options == [.duplicateSort, .duplicateFixed])
        #expect(reopened.options == [.duplicateSort, .duplicateFixed])
    }

    @Test func reverseKeyOrder() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "reversed", options: .reverseKey)
        try env.write { txn in
            for key in ["ab", "ba", "ca"] { try txn.put(1, forKey: key, in: db) }
        }
        let keys = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var keys: [String] = []
            while let entry = try cursor.next() { keys.append(try entry.key(as: String.self)) }
            return keys
        }
        // Compared from the last byte: "ba" < "ca" < "ab".
        #expect(keys == ["ba", "ca", "ab"])
    }
}
