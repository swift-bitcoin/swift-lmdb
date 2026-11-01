// expected-error: requires that 'RawSpan' conform to 'Escapable'
import LMDB

func leak(env: borrowing Environment, db: Database) throws {
    let key: [UInt8] = [1]
    let span: RawSpan? = try env.read { txn in try txn.value(forKey: key.span.bytes, in: db) }
    _ = span
}
