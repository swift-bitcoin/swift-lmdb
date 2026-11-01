// expected-error: borrowed by a non-Escapable type
import LMDB

func closeEarly(path: String) throws {
    let env = try Environment(path: path)
    let txn = try ReadTransaction(env)
    _ = consume env
    _ = txn
}
