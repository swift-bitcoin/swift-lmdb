// expected-error: requires that 'WriteTransaction' conform to 'Escapable'
import LMDB

func smuggle(env: borrowing Environment) throws {
    let txn: WriteTransaction = try env.write { txn in txn }
    _ = txn
}
