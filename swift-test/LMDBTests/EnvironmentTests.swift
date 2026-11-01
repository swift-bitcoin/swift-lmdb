import Foundation
import LMDB
import Testing

@Suite struct EnvironmentTests {
    @Test func linkedVersion() {
        let version = lmdbVersion
        #expect(version.major == 0)
        #expect(version.minor == 9)
    }

    @Test func missingDirectoryThrows() {
        #expect(throws: LMDBError.self) {
            _ = try Environment(path: "/nonexistent/\(UUID().uuidString)")
        }
    }

    @Test func namedDatabasesAreIndependent() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 2)
        let a = try env.openDatabase(named: "a")
        let b = try env.openDatabase(named: "b")
        let key = bytes("shared")

        try env.write { txn in
            try txn.put(bytes("in a").span.bytes, forKey: key.span.bytes, in: a)
            try txn.put(bytes("in b").span.bytes, forKey: key.span.bytes, in: b)
        }
        let (inA, inB) = try env.read { txn in
            (try txn.bytes(forKey: key.span.bytes, in: a),
             try txn.bytes(forKey: key.span.bytes, in: b))
        }
        #expect(inA == bytes("in a"))
        #expect(inB == bytes("in b"))
    }

    @Test func tooManyDatabasesThrows() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        _ = try env.openDatabase(named: "first")
        #expect(throws: LMDBError.databasesFull) {
            try env.openDatabase(named: "second")
        }
    }

    @Test func dataSurvivesReopening() throws {
        let dir = try TemporaryDirectory()
        let key = bytes("k")
        do {
            let env = try Environment(path: dir.path, maxDatabases: 1)
            let db = try env.openDatabase(named: "persisted")
            try env.write { txn in
                try txn.put(bytes("still here").span.bytes, forKey: key.span.bytes, in: db)
            }
        }
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "persisted")
        let stored = try env.read { txn in try txn.bytes(forKey: key.span.bytes, in: db) }
        #expect(stored == bytes("still here"))
    }

    @Test func errorsDescribeThemselves() {
        #expect(LMDBError.notFound.description.contains("MDB_NOTFOUND"))
    }
}
