// expected-error: lifetime-dependent value escapes its scope
import LMDB

func leak(path: String) throws -> ResetReadTransaction {
    let env = try Environment(path: path)
    return try ReadTransaction(env).reset()
}
