// expected-error: escapes its scope
import LMDB

final class Holder {
    var txn: ReadTransaction? = nil
}
