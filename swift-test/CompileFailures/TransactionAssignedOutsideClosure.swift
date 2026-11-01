// expected-error: lifetime-dependent variable 'outer' escapes its scope
import LMDB

func smuggle(env: borrowing Environment) throws {
    var outer: WriteTransaction? = nil
    try env.write { txn in outer = consume txn }
}
