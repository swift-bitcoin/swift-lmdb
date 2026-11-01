// expected-error: borrowed by a non-Escapable type
import LMDB

// A cursor belongs to the snapshot that reset() releases.
func stale(env: borrowing Environment, db: Database) throws {
    let txn = try ReadTransaction(env)
    let cursor = try Cursor(txn, database: db)
    let reset = txn.reset()
    _ = try cursor.first()
    _ = reset
}
