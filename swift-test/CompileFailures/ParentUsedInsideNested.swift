// expected-error: overlapping accesses to 'txn'
import LMDB

// LMDB forbids using a parent transaction while it has an active child.
func write(env: borrowing Environment, db: Database) throws {
    try env.write { txn in
        try txn.nested { child in
            try txn.put(1, forKey: 1, in: db)
        }
    }
}
