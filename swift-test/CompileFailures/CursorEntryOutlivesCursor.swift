// expected-error: requires that 'CursorEntry' conform to 'Escapable'
import LMDB

func leak(env: borrowing Environment, db: Database) throws {
    let entry: CursorEntry? = try env.read { txn in
        let cursor = try Cursor(txn, database: db)
        return try cursor.first()
    }
    _ = entry
}
