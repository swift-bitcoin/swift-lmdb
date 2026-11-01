// expected-error: overlapping accesses to 'txn'
import LMDB

func invalidate(env: borrowing Environment, db: Database) throws {
    let key: [UInt8] = [1]
    try env.write { txn in
        let span = try txn.value(forKey: key.span.bytes, in: db)
        try txn.put(key.span.bytes, forKey: key.span.bytes, in: db)
        _ = span?.byteCount
    }
}
