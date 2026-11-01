// expected-error: overlapping accesses to 'env'
import LMDB

// LMDB requires no open transactions in the process when resizing the map.
func resize(path: String) throws {
    var env = try Environment(path: path)
    try env.read { txn in
        try env.setMapSize(1 << 30)
    }
}
