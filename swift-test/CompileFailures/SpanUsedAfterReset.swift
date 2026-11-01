// expected-error: borrowed by a non-Escapable type
import LMDB

// reset() releases the snapshot a span points into.
func stale(env: borrowing Environment, db: Database) throws {
    let txn = try ReadTransaction(env)
    let span = try txn.value(forKey: 1, in: db)
    let reset = txn.reset()
    _ = span?.byteCount
    _ = reset
}
