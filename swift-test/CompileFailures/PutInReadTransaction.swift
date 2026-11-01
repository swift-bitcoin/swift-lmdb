// expected-error: has no member 'put'
import LMDB

// swift-bitcoin checks this at runtime (`readOnlyDatabase`); here a read
// transaction has no write methods at all.
func write(env: borrowing Environment, db: Database) throws {
    try env.read { txn in
        try txn.put("v", forKey: "k", in: db)
    }
}
