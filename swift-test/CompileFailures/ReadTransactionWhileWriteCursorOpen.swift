// expected-error: overlapping accesses to 'txn'
import LMDB

func read(env: borrowing Environment, db: Database) throws {
    try env.write { txn in
        var cursor = try Cursor(&txn, database: db)
        _ = try txn.bytes(forKey: [1].span.bytes, in: db)
        try cursor.delete()
    }
}
