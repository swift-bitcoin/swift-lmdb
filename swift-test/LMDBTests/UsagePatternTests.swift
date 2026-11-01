import Foundation
import LMDB
import Testing

/// Behaviour that swift-bitcoin's LMDB tests (test/lmdb) and its block and coin
/// indexes (src/bitcoin-blockchain) rely on, checked against this wrapper.
@Suite struct UsagePatternTests {
    // MARK: From swift-bitcoin's LMDBTests

    @Test func versionString() {
        #expect(lmdbVersionString.hasPrefix("LMDB \(lmdbVersion.major).\(lmdbVersion.minor).\(lmdbVersion.patch)"))
    }

    /// `LMDBTests.stats`: a single entry fits one leaf page, and LMDB's page
    /// size is the system's.
    @Test func statisticsOfASingleEntry() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put("value", forKey: "key", in: db) }

        let stats = try env.statistics(for: db)
        #expect(stats.pageSize == Int(getpagesize()))
        #expect(stats.depth == 1)
        #expect(stats.branchPages == 0)
        #expect(stats.leafPages == 1)
        #expect(stats.overflowPages == 0)
        #expect(stats.entries == 1)
    }

    /// `LMDBTests.putGet`'s edge values, plus the ones it leaves out.
    @Test func floatingPointEdgeValuesRoundTrip() throws {
        let doubles: [Double] = [.leastNormalMagnitude, .leastNonzeroMagnitude, .greatestFiniteMagnitude,
                                 -.leastNonzeroMagnitude, .pi, -.infinity]
        let floats: [Float] = [.leastNormalMagnitude, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        #expect(try storedInKeyOrder(doubles.sorted()).roundTrip == doubles.sorted())
        #expect(try storedInKeyOrder(floats.sorted()).roundTrip == floats.sorted())
    }

    /// NaN is not equal to itself, so compare bit patterns: the encoding is
    /// a bijection on bits, and preserves NaN payloads and signs.
    @Test func nanKeepsItsBits() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        let nans = [Double.nan, -Double.nan, Double.signalingNaN, Double(nan: 0x1234, signaling: false)]
        try env.write { txn in
            for (i, nan) in nans.enumerated() { try txn.put(nan, forKey: i, in: db) }
        }
        let stored = try env.read { txn in
            try nans.indices.map { try #require(try txn.value(forKey: $0, in: db, as: Double.self)) }
        }
        #expect(stored.map(\.bitPattern) == nans.map(\.bitPattern))
    }

    @Test func extremeDatesRoundTripInOrder() throws {
        let dates = [Date.distantPast, Date(timeIntervalSince1970: 0), .distantFuture]
        #expect(try storedInKeyOrder(dates) == (dates, dates))
    }

    @Test func nonASCIIStringsRoundTrip() throws {
        let strings = ["Hello world! 👋🏼", "ÆØÅ", "👩‍👩‍👧‍👦"].sorted { Array($0.utf8).lexicographicallyPrecedes($1.utf8) }
        #expect(try storedInKeyOrder(strings) == (strings, strings))
    }

    /// `LMDBTests.dropDatabase` drops the main database: LMDB can only empty
    /// it, and the handle stays usable.
    @Test func droppingTheMainDatabaseEmptiesIt() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let main = try env.openDatabase()
        try env.write { txn in try txn.put(1, forKey: 1, in: main) }

        try env.write { txn in try txn.dropDatabase(main) }
        try env.write { txn in try txn.put(2, forKey: 2, in: main) }
        let (one, two) = try env.read { txn in
            (try txn.value(forKey: 1, in: main, as: Int.self), try txn.value(forKey: 2, in: main, as: Int.self))
        }
        #expect(one == nil)
        #expect(two == 2)
    }

    // MARK: From swift-bitcoin's DuplicatesTests

    /// `DuplicatesTests`: a plain read of a key with several values returns
    /// the first in sort order.
    @Test func plainReadOfDuplicateKeyReturnsFirstValue() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            for value: [UInt8] in [[5, 0, 5], [2, 1, 0], [6, 0, 0]] { try txn.put(value, forKey: 3, in: db) }
        }
        let first = try env.read { txn in try txn.value(forKey: 3, in: db, as: [UInt8].self) }
        #expect(first == [2, 1, 0])
    }

    /// `DuplicatesTests` stores 2-, 3- and 4-byte values under different keys
    /// of one `.duplicateFixed` database: the size is fixed per key, not per
    /// database.
    @Test func fixedValueSizeIsPerKey() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "dups", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            for value: [UInt8] in [[8, 1], [9, 9]] { try txn.put(value, forKey: 2, in: db) }
            for value: [UInt8] in [[6, 0, 0], [2, 1, 0], [5, 0, 5]] { try txn.put(value, forKey: 3, in: db) }
            for value: [UInt8] in [[1, 1, 2, 2], [0, 0, 0, 1]] { try txn.put(value, forKey: 4, in: db) }
        }
        let (two, three, four) = try env.read { txn in
            // Not a local helper function: capturing the non-escapable cursor
            // in one counts as an escape.
            let cursor = try Cursor(txn, database: db)
            var batches: [[UInt8]?] = []
            for key in [2, 3, 4] {
                _ = try cursor.seek(to: key)
                batches.append(try cursor.duplicateBatch()?.valuesBytes)
            }
            return (batches[0], batches[1], batches[2])
        }
        #expect(two == [8, 1, 9, 9])
        #expect(three == [2, 1, 0, 5, 0, 5, 6, 0, 0])
        #expect(four == [0, 0, 0, 1, 1, 1, 2, 2])
    }

    // MARK: From swift-bitcoin's block index

    /// Heights to block IDs, as in the `by-height` database: several blocks
    /// at a height when the chain forks.
    func heights(_ env: borrowing Environment) throws -> Database {
        let db = try env.openDatabase(named: "by-height", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            for (height, ids) in [(0, ["genesis"]), (1, ["a1", "b1"]), (2, ["a2"]), (3, ["a3", "b3", "c3"])] {
                for id in ids { try txn.put(id.padding(toLength: 8, withPad: "_", startingAt: 0), forKey: height, in: db) }
            }
        }
        return db
    }

    /// `HybridBlockIndex.init`: walk forward with `nextDuplicate`, then
    /// `nextKey`.
    @Test func forwardWalkByHeight() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try heights(env)

        let walked = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var walked: [String] = []
            var entry = try cursor.first()
            while let current = entry {
                walked.append("\(try current.key(as: Int.self)):\(try current.value(as: String.self))")
                // Not `??`: it does not accept non-escapable values yet.
                if let next = try cursor.nextDuplicate() { entry = next } else { entry = try cursor.nextKey() }
            }
            return walked
        }
        #expect(walked == ["0:genesis_", "1:a1______", "1:b1______", "2:a2______",
                           "3:a3______", "3:b3______", "3:c3______"])
    }

    /// `PersistentBlockIndex.bestHeader` / `findBestBlock`: walk backward from
    /// the tip with `previousDuplicate`, then `previousKey`, which must land
    /// on the *last* value of the previous height.
    @Test func backwardWalkFromTheTip() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try heights(env)

        let walked = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            var walked: [String] = []
            var entry = try cursor.last()
            while let current = entry {
                walked.append("\(try current.key(as: Int.self)):\(try current.value(as: String.self))")
                if let previous = try cursor.previousDuplicate() {
                    entry = previous
                } else {
                    entry = try cursor.previousKey()
                }
            }
            return walked
        }
        #expect(walked == ["3:c3______", "3:b3______", "3:a3______", "2:a2______",
                           "1:b1______", "1:a1______", "0:genesis_"])
    }

    /// `PersistentBlockIndex.get(at:)`: position on a height with a cursor
    /// over one database, and look each block up in another, in the same
    /// transaction.
    @Test func cursorOverOneDatabaseLookupsInAnother() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 2)
        let byHeight = try heights(env)
        let byID = try env.openDatabase(named: "by-id")
        try env.write { txn in
            for id in ["a3", "b3", "c3"] {
                try txn.put("block \(id)", forKey: id.padding(toLength: 8, withPad: "_", startingAt: 0), in: byID)
            }
        }

        let blocks = try env.read { txn in
            let cursor = try Cursor(txn, database: byHeight)
            var blocks: [String] = []
            var entry = try cursor.seek(to: 3)
            while let current = entry {
                let id = try current.value(as: String.self)
                blocks.append(try #require(try txn.value(forKey: id, in: byID, as: String.self)))
                entry = try cursor.nextDuplicate()
            }
            return blocks
        }
        #expect(blocks == ["block a3", "block b3", "block c3"])
    }

    // MARK: From swift-bitcoin's coin index

    /// `PersistentCoinIndex.update(remove:add:)`: read, delete and insert in one
    /// write transaction, failing the whole update if a spent coin is missing.
    @Test func coinUpdateIsAtomic() throws {
        struct SpentCoinNotFound: Error {}
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let coins = try env.openDatabase(named: "by-id")
        try env.write { txn in try txn.put(50, forKey: "coin-a", in: coins) }

        func update(remove: [String], add: [String: Int]) throws -> [Int?] {
            try env.write { txn in
                var removed: [Int?] = []
                for outpoint in remove {
                    let coin = try txn.value(forKey: outpoint, in: coins, as: Int.self)
                    removed.append(coin)
                    guard coin != nil else { continue }
                    guard try txn.delete(forKey: outpoint, in: coins) else { throw SpentCoinNotFound() }
                }
                for (outpoint, coin) in add { try txn.put(coin, forKey: outpoint, in: coins) }
                return removed
            }
        }

        let removed = try update(remove: ["coin-a", "coin-missing"], add: ["coin-b": 30, "coin-c": 20])
        let (a, b, count) = try env.read { txn in
            (try txn.value(forKey: "coin-a", in: coins, as: Int.self),
             try txn.value(forKey: "coin-b", in: coins, as: Int.self),
             try txn.count(in: coins))
        }
        #expect(removed == [50, nil])
        #expect(a == nil)
        #expect(b == 30)
        #expect(count == 2)
    }

    /// The indexes keep the environment in an actor, as an optional so
    /// `clear()` can close it, delete the files and reopen.
    @Test func environmentOwnedByAnActor() async throws {
        let dir = try TemporaryDirectory()
        let index = try CoinIndex(path: dir.path + "/coins")
        try await index.add("utxo", for: 1)
        #expect(try await index.get(1) == "utxo")

        try await index.clear()
        #expect(try await index.get(1) == nil)
        try await index.add("after clear", for: 1)
        #expect(try await index.get(1) == "after clear")
    }
}

/// The shape of swift-bitcoin's `PersistentCoinIndex`, on this wrapper.
private actor CoinIndex {
    private var env: Environment?
    private var db: Database
    private let path: String

    init(path: String) throws {
        self.path = path
        let env = try Environment(path: path, options: .noSubdirectory, maxDatabases: 1)
        db = try env.openDatabase(named: "by-id")
        self.env = consume env
    }

    func get(_ key: Int) throws -> String? {
        try env!.read { txn in try txn.value(forKey: key, in: db, as: String.self) }
    }

    func add(_ value: String, for key: Int) throws {
        try env!.write { txn in try txn.put(value, forKey: key, in: db) }
    }

    func clear() throws {
        env = nil   // closes the environment
        for file in [path, path + "-lock"] { try FileManager.default.removeItem(atPath: file) }
        let env = try Environment(path: path, options: .noSubdirectory, maxDatabases: 1)
        db = try env.openDatabase(named: "by-id")
        self.env = consume env
    }
}
