// expected-error: lifetime-dependent value escapes its scope
import LMDB

// The cursor may depend on the environment, but it is opened from a
// transaction that ends when this function returns.
@_lifetime(borrow env)
func leak(env: borrowing Environment, db: Database) throws -> Cursor<ReadOnly> {
    let txn = try ReadTransaction(env)
    return try Cursor(txn, database: db)
}
