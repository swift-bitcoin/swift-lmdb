// expected-error: lifetime-dependent value escapes its scope
import LMDB

func leak(path: String) throws -> ReadTransaction {
    let env = try Environment(path: path)
    return try ReadTransaction(env)
}
