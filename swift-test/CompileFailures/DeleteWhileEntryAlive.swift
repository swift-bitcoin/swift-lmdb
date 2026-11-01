// expected-error: overlapping accesses to 'cursor'
import LMDB

func filter(env: borrowing Environment, db: Database) throws {
    try env.write { txn in
        var cursor = try Cursor(&txn, database: db)
        while let entry = try cursor.next() {
            if entry.key.byteCount > 1 { try cursor.delete() }
        }
    }
}
