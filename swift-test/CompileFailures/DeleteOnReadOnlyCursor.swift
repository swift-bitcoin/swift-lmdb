// expected-error: 'ReadOnly' and 'ReadWrite' be equivalent
import LMDB

func delete(env: borrowing Environment, db: Database) throws {
    try env.read { txn in
        var cursor = try Cursor(txn, database: db)
        try cursor.delete()
    }
}
