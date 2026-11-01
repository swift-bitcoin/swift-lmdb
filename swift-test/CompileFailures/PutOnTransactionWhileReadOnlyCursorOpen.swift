// expected-error: overlapping accesses to 'txn'
import LMDB

func write(env: borrowing Environment, db: Database) throws {
    try env.write { txn in
        let cursor = try Cursor(txn, database: db)
        try txn.put([1].span.bytes, forKey: [1].span.bytes, in: db)
        _ = try cursor.first()
    }
}
