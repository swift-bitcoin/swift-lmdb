import Foundation
import LMDB
import Testing

/// Stores each of `values` as both key and value, then checks that they come
/// back equal, and in `values`' order when iterated by key.
func storedInKeyOrder<T: LMDBCodable & Equatable>(_ values: [T]) throws -> (roundTrip: [T], keyOrder: [T]) {
    let dir = try TemporaryDirectory()
    let env = try Environment(path: dir.path)
    let db = try env.openDatabase()
    // Insert in reverse so a passing order check cannot come from insertion order.
    try env.write { txn in
        for value in values.reversed() { try txn.put(value, forKey: value, in: db) }
    }
    return try env.read { txn in
        let roundTrip = try values.map { try #require(try txn.value(forKey: $0, in: db, as: T.self)) }
        var keyOrder: [T] = []
        let cursor = try Cursor(txn, database: db)
        while let entry = try cursor.next() { keyOrder.append(try entry.key(as: T.self)) }
        return (roundTrip, keyOrder)
    }
}

/// A user-defined key: sorted by `x`, then `y`.
struct GridPoint: LMDBCodable, Equatable {
    var x: Int32
    var y: Int32

    var encodedByteCount: Int { 8 }

    func encode(into output: inout OutputRawSpan) {
        x.encode(into: &output)
        y.encode(into: &output)
    }

    init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }

    init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        guard bytes.byteCount == 8 else {
            throw LMDBDecodingError(Self.self, byteCount: bytes.byteCount, reason: "expected 8 bytes")
        }
        x = try Int32(lmdbBytes: bytes.extracting(0..<4))
        y = try Int32(lmdbBytes: bytes.extracting(4..<8))
    }
}

@Suite struct CodingTests {
    // MARK: Round trips in key order

    @Test func signedIntegersSortNumerically() throws {
        let values = [Int.min, -1_000_000, -256, -1, 0, 1, 255, 256, Int.max]
        let (roundTrip, keyOrder) = try storedInKeyOrder(values)
        #expect(roundTrip == values)
        #expect(keyOrder == values)
    }

    @Test func sizedIntegersSortNumerically() throws {
        let int8: [Int8] = [.min, -1, 0, 1, .max]
        let int16: [Int16] = [.min, -300, 0, 300, .max]
        let int32: [Int32] = [.min, -70_000, 0, 70_000, .max]
        let int64: [Int64] = [.min, -1, 0, 1, .max]
        #expect(try storedInKeyOrder(int8) == (int8, int8))
        #expect(try storedInKeyOrder(int16) == (int16, int16))
        #expect(try storedInKeyOrder(int32) == (int32, int32))
        #expect(try storedInKeyOrder(int64) == (int64, int64))
    }

    @Test func unsignedIntegersSortNumerically() throws {
        let uint8: [UInt8] = [0, 1, 128, .max]
        let uint16: [UInt16] = [0, 255, 256, .max]
        let uint32: [UInt32] = [0, 1, 65_536, .max]
        let uint64: [UInt64] = [0, 1, 1 << 40, .max]
        let uint: [UInt] = [0, 1, .max]
        #expect(try storedInKeyOrder(uint8) == (uint8, uint8))
        #expect(try storedInKeyOrder(uint16) == (uint16, uint16))
        #expect(try storedInKeyOrder(uint32) == (uint32, uint32))
        #expect(try storedInKeyOrder(uint64) == (uint64, uint64))
        #expect(try storedInKeyOrder(uint) == (uint, uint))
    }

    @Test func floatingPointSortsNumerically() throws {
        let doubles: [Double] = [-.infinity, -1e300, -2.5, -1e-300, 0, 1e-300, 1, 2.5, 1e300, .infinity]
        let floats: [Float] = [-.infinity, -3.5, -1, 0, 0.25, 1, .greatestFiniteMagnitude, .infinity]
        #expect(try storedInKeyOrder(doubles) == (doubles, doubles))
        #expect(try storedInKeyOrder(floats) == (floats, floats))
    }

    @Test func negativeZeroSortsBeforeZeroAndKeepsItsSign() throws {
        let (roundTrip, _) = try storedInKeyOrder([-0.0, 0.0])
        #expect(roundTrip[0].sign == .minus)
        #expect(roundTrip[1].sign == .plus)
    }

    @Test func datesSortChronologically() throws {
        let dates = [
            Date(timeIntervalSince1970: -1_000_000_000),
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSinceReferenceDate: 0),
            Date(timeIntervalSinceReferenceDate: 0.001),
            Date(timeIntervalSince1970: 2_000_000_000.5),
        ]
        #expect(try storedInKeyOrder(dates) == (dates, dates))
    }

    @Test func stringsSortByScalarValue() throws {
        let strings = ["A", "Z", "a", "ab", "z", "é", "日本"]
        #expect(try storedInKeyOrder(strings) == (strings, strings))
    }

    @Test func booleans() throws {
        #expect(try storedInKeyOrder([false, true]) == ([false, true], [false, true]))
    }

    @Test func uuidsSortLikeTheirStrings() throws {
        let uuids = (0..<50).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        #expect(try storedInKeyOrder(uuids) == (uuids, uuids))
    }

    @Test func bytesAndData() throws {
        let arrays: [[UInt8]] = [[0], [0, 0], [1], [1, 2, 3], [255]]
        let data = arrays.map { Data($0) }
        #expect(try storedInKeyOrder(arrays) == (arrays, arrays))
        #expect(try storedInKeyOrder(data) == (data, data))
    }

    @Test func customTypeSortsByItsEncoding() throws {
        let points = [GridPoint(x: -1, y: 5), GridPoint(x: 0, y: -3), GridPoint(x: 0, y: 2), GridPoint(x: 7, y: 0)]
        #expect(try storedInKeyOrder(points) == (points, points))
    }

    // MARK: Values that cannot be keys

    /// LMDB rejects empty keys, but empty values are fine.
    @Test func emptyValues() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in
            try txn.put("", forKey: "string", in: db)
            try txn.put([UInt8](), forKey: "bytes", in: db)
        }
        let (string, bytes) = try env.read { txn in
            (try txn.value(forKey: "string", in: db, as: String.self),
             try txn.value(forKey: "bytes", in: db, as: [UInt8].self))
        }
        #expect(string == "")
        #expect(bytes == [])
        #expect(throws: LMDBError.badValueSize) {
            try env.write { txn in try txn.put(1, forKey: "", in: db) }
        }
    }

    // MARK: Decoding errors

    @Test func wrongSizeIsADecodingError() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put([UInt8]([1, 2, 3]), forKey: "k", in: db) }

        #expect(throws: LMDBDecodingError.self) {
            try env.read { txn in try txn.value(forKey: "k", in: db, as: Int.self) }
        }
    }

    @Test func invalidUTF8IsADecodingError() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put([UInt8]([0x61, 0xFF]), forKey: "k", in: db) }

        let error = #expect(throws: LMDBDecodingError.self) {
            try env.read { txn in try txn.value(forKey: "k", in: db, as: String.self) }
        }
        #expect(error?.typeName == "String")
    }

    @Test func boolRejectsOtherBytes() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put(UInt8(2), forKey: "k", in: db) }
        #expect(throws: LMDBDecodingError.self) {
            try env.read { txn in try txn.value(forKey: "k", in: db, as: Bool.self) }
        }
    }

    // MARK: Typed APIs

    @Test func typedRangeScanOverDates() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let events = try env.openDatabase(named: "events")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try env.write { txn in
            for hour in 0..<48 {
                try txn.put("event \(hour)", forKey: start.addingTimeInterval(Double(hour) * 3600), in: events)
            }
        }

        // Everything in the second day.
        let from = start.addingTimeInterval(24 * 3600)
        let to = start.addingTimeInterval(48 * 3600)
        let names = try env.read { txn in
            let cursor = try Cursor(txn, database: events)
            var names: [String] = []
            var entry = try cursor.seek(atOrAfter: from)
            while let current = entry, try current.key(as: Date.self) < to {
                names.append(try current.value(as: String.self))
                entry = try cursor.next()
            }
            return names
        }
        #expect(names == (24..<48).map { "event \($0)" })
    }

    @Test func typedCursorSeeks() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "scores", options: .duplicateSort)
        try env.write { txn in
            for (player, score) in [("ann", 10), ("ann", 30), ("bob", 20)] {
                try txn.put(score, forKey: player, in: db)
            }
        }
        let (exact, both, range) = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            let exact = try cursor.seek(to: "bob")?.value(as: Int.self)
            let both = try cursor.seek(to: "ann", value: 30)?.value(as: Int.self)
            let range = try cursor.seek(to: "ann", valueAtOrAfter: 15)?.value(as: Int.self)
            return (exact, both, range)
        }
        #expect(exact == 20)
        #expect(both == 30)
        #expect(range == 30)
    }

    @Test func typedCursorPut() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in
            var cursor = try Cursor(&txn, database: db)
            try cursor.put(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!, forKey: 42)
        }
        let stored = try env.read { txn in try txn.value(forKey: 42, in: db, as: UUID.self) }
        #expect(stored?.uuidString == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
    }

    @Test func typedDuplicateBatch() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path, maxDatabases: 1)
        let db = try env.openDatabase(named: "fixed", options: [.duplicateSort, .duplicateFixed])
        try env.write { txn in
            for n: UInt32 in [30, 10, 20] { try txn.put(n, forKey: "k", in: db) }
        }
        let values = try env.read { txn in
            let cursor = try Cursor(txn, database: db)
            _ = try cursor.seek(to: "k")
            return try cursor.duplicateBatch()?.values(as: UInt32.self, valueSize: 4)
        }
        #expect(values == [10, 20, 30])
    }

    /// Typed and untyped access agree on the bytes.
    @Test func typedAndRawAgree() throws {
        let dir = try TemporaryDirectory()
        let env = try Environment(path: dir.path)
        let db = try env.openDatabase()
        try env.write { txn in try txn.put(UInt32(0x0102_0304), forKey: "k", in: db) }
        let raw = try env.read { txn in try txn.bytes(forKey: bytes("k").span.bytes, in: db) }
        #expect(raw == [1, 2, 3, 4])
    }
}
