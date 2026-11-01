import Foundation
import LMDB

/// A fresh environment directory per test, removed afterwards.
struct TemporaryDirectory: ~Copyable {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("LMDBTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }
