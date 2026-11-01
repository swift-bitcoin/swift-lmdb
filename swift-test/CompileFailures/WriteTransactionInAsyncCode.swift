// expected-error: unavailable from asynchronous contexts
import LMDB

func writeAcrossAwait(env: borrowing Environment) async throws {
    let txn = try WriteTransaction(env)
    try txn.commit()
}
