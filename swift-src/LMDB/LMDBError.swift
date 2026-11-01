import CLMDBInterop

/// An error reported by LMDB: any return code other than `MDB_SUCCESS`.
///
/// LMDB reports both its own errors (negative `MDB_*` codes) and system
/// `errno` values, such as `ENOENT` or `EACCES`, through the same integer, so
/// this wraps the code rather than enumerating cases. The common LMDB codes
/// have named constants, which also work as patterns:
///
/// ```swift
/// do {
///     try txn.put(value, forKey: key, in: db, options: .noOverwrite)
/// } catch .keyExists {
///     // already there
/// }
/// ```
///
/// ``description`` is LMDB's own message for the code (`mdb_strerror`).
public struct LMDBError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The raw return code: a negative `MDB_*` value, or a positive `errno`.
    public let code: Int32

    /// Creates an error for a raw LMDB or `errno` code.
    public init(code: Int32) { self.code = code }

    /// LMDB's description of the code, which also covers `errno` values.
    public var description: String {
        unsafe String(cString: mdb_strerror(code))
    }

    /// The key/value pair already exists (`MDB_KEYEXIST`).
    ///
    /// From a put with ``PutOptions/noOverwrite`` or
    /// ``PutOptions/noDuplicateData``, or with ``PutOptions/append`` and a
    /// key out of order.
    public static let keyExists = LMDBError(code: MDB_KEYEXIST)

    /// No matching key or value was found (`MDB_NOTFOUND`).
    ///
    /// Reads return `nil` rather than throwing this; it surfaces from
    /// operations that need an existing entry.
    public static let notFound = LMDBError(code: MDB_NOTFOUND)

    /// The environment's map size has been reached (`MDB_MAP_FULL`).
    ///
    /// The write transaction can't continue. Grow the map with
    /// ``Environment/setMapSize(_:)`` and retry.
    public static let mapFull = LMDBError(code: MDB_MAP_FULL)

    /// The environment's `maxDatabases` limit has been reached
    /// (`MDB_DBS_FULL`).
    public static let databasesFull = LMDBError(code: MDB_DBS_FULL)

    /// The environment's `maxReaders` limit has been reached: too many read
    /// transactions are open (`MDB_READERS_FULL`).
    ///
    /// Stale slots left by crashed processes count too; see
    /// ``Environment/clearStaleReaders()``.
    public static let readersFull = LMDBError(code: MDB_READERS_FULL)

    /// The transaction has too many dirty pages (`MDB_TXN_FULL`). Split the
    /// work into smaller transactions.
    public static let transactionFull = LMDBError(code: MDB_TXN_FULL)

    /// Another process grew the map beyond this environment's size
    /// (`MDB_MAP_RESIZED`).
    ///
    /// Call ``Environment/setMapSize(_:)`` with `0` to adopt the new size,
    /// then retry.
    public static let mapResized = LMDBError(code: MDB_MAP_RESIZED)

    /// The operation is incompatible with the database's options, or the
    /// database was dropped and recreated with different options
    /// (`MDB_INCOMPATIBLE`).
    ///
    /// For example, a duplicate operation on a database without
    /// ``DatabaseOptions/duplicateSort``.
    public static let incompatible = LMDBError(code: MDB_INCOMPATIBLE)

    /// A key or value has an unsupported size (`MDB_BAD_VALSIZE`).
    ///
    /// An empty key, a key longer than ``Environment/maxKeySize``, or a value
    /// of the wrong size for a ``DatabaseOptions/duplicateFixed`` database.
    public static let badValueSize = LMDBError(code: MDB_BAD_VALSIZE)

    /// The transaction can no longer be used, after an earlier error in it
    /// (`MDB_BAD_TXN`). Abort it.
    public static let badTransaction = LMDBError(code: MDB_BAD_TXN)

    /// The database handle is unknown, or was invalidated, for example by
    /// ``WriteTransaction/dropDatabase(_:)`` (`MDB_BAD_DBI`).
    public static let badDatabase = LMDBError(code: MDB_BAD_DBI)

    /// The file is not an LMDB data file (`MDB_INVALID`).
    public static let invalid = LMDBError(code: MDB_INVALID)

    /// The data file was written by an incompatible LMDB version
    /// (`MDB_VERSION_MISMATCH`).
    public static let versionMismatch = LMDBError(code: MDB_VERSION_MISMATCH)

    /// A page has an unexpected type: the database is corrupted
    /// (`MDB_CORRUPTED`).
    public static let corrupted = LMDBError(code: MDB_CORRUPTED)

    /// An earlier fatal error left the environment unusable (`MDB_PANIC`).
    /// Close it.
    public static let panic = LMDBError(code: MDB_PANIC)
}

/// Stored bytes that are not a valid encoding of the requested type.
///
/// Thrown by ``LMDBDecodable/init(lmdbBytes:)``, and so by typed reads such
/// as ``ReadTransaction/value(forKey:in:as:)``, for example when a 3-byte
/// value is read as an `Int`, or invalid UTF-8 as a `String`.
public struct LMDBDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The name of the type that was being decoded.
    public let typeName: String
    /// How many bytes were stored.
    public let byteCount: Int
    /// Why the bytes were rejected.
    public let reason: String

    /// Creates an error for `byteCount` bytes that don't decode as `type`.
    ///
    /// For custom ``LMDBDecodable`` conformances.
    public init<T>(_ type: T.Type, byteCount: Int, reason: String) {
        self.typeName = String(describing: type)
        self.byteCount = byteCount
        self.reason = reason
    }

    public var description: String {
        "cannot decode \(byteCount) bytes as \(typeName): \(reason)"
    }
}

/// Throws for any return code other than `MDB_SUCCESS`.
@inline(__always)
func check(_ rc: Int32) throws(LMDBError) {
    guard rc == MDB_SUCCESS else { throw LMDBError(code: rc) }
}
