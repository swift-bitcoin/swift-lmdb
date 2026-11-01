// expected-error: borrowed by a non-Escapable type
import LMDB

func commitEarly(env: borrowing Environment, db: Database) throws {
    let txn = try WriteTransaction(env)
    let cursor = try Cursor(txn, database: db)
    try txn.commit()
    _ = try cursor.first()
}
