// expected-error: 'txn' used after consume
import LMDB

func reuse(env: borrowing Environment, db: Database) throws {
    var txn = try WriteTransaction(env)
    try txn.commit()
    try txn.put([1].span.bytes, forKey: [1].span.bytes, in: db)
}
