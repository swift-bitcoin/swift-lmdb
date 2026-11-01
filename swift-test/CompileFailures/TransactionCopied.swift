// expected-error: 'copy' cannot be applied to noncopyable types
import LMDB

func duplicate(env: borrowing Environment) throws {
    try env.read { txn in
        let second = copy txn
        _ = second
    }
}
