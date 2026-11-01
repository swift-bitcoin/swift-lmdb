import CLMDBInterop
import Synchronization

/// An open LMDB environment: a memory-mapped database file holding one main
/// database and, optionally, a number of named databases.
///
/// An environment is the unit of storage, locking and transactions. Every
/// ``ReadTransaction`` and ``WriteTransaction`` is begun from one, and every
/// ``Database`` handle belongs to one.
///
/// ```swift
/// let env = try Environment(path: directory, maxDatabases: 2)
/// let users = try env.openDatabase(named: "users")
/// try env.write { txn in try txn.put("Alice", forKey: 42, in: users) }
/// ```
///
/// `Environment` is non-copyable: it has exactly one owner, and the
/// environment is closed (`mdb_env_close`) exactly once, when that owner
/// goes away. Transactions depend on a borrow of the environment, so the
/// compiler guarantees it outlives all of them.
///
/// An environment may be used from several threads at once, so it is
/// `Sendable`. To share one, store it in an actor or a `final class` and
/// borrow it from there.
///
/// Don't open the same environment twice in one process at the same time:
/// LMDB's locks are per process, and a second `Environment` for the same
/// files would bypass them.
public struct Environment: ~Copyable, Sendable {
    let raw: MDB_env

    /// Serializes the calls LMDB forbids running concurrently in one process:
    /// opening databases in a read-only environment (where no writer lock
    /// orders them) and changing flags.
    private let configurationLock = Mutex(())

    /// Opens the environment at `path`, creating its files if they don't
    /// exist yet.
    ///
    /// - Parameters:
    ///   - path: The directory in which the database files reside, which must
    ///     already exist and be writable. LMDB creates `data.mdb` and
    ///     `lock.mdb` in it. With ``EnvironmentOptions/noSubdirectory``, the
    ///     path of the data file itself; the lock file is that path plus
    ///     `-lock`.
    ///   - options: How the environment is opened. See ``EnvironmentOptions``.
    ///   - maxDatabases: The maximum number of named databases, fixed until
    ///     the environment is closed. Only needed if named databases are used.
    ///     A moderate number is cheap; a huge one costs memory in every
    ///     transaction and time in every ``openDatabase(named:options:)``.
    ///   - maxReaders: The number of slots in the reader table, which bounds
    ///     how many read transactions may be open at once, across all
    ///     processes. `nil` keeps LMDB's default of 126.
    ///   - mapSize: The size of the memory map in bytes, which is also the
    ///     maximum size of the database. It should be a multiple of the OS
    ///     page size, and as large as possible to accommodate future growth:
    ///     address space is reserved, not memory. Writes beyond it fail with
    ///     ``LMDBError/mapFull``; see ``setMapSize(_:)``.
    ///   - fileMode: The POSIX permissions for newly created files.
    /// - Throws: ``LMDBError`` if the environment can't be created or opened,
    ///   for example because `path` doesn't exist (`ENOENT`) or is not
    ///   writable (`EACCES`), or the file is not an LMDB database
    ///   (``LMDBError/invalid``).
    public init(
        path: String,
        options: EnvironmentOptions = [],
        maxDatabases: Int = 0,
        maxReaders: Int? = nil,
        mapSize: Int = 10 * 1024 * 1024,
        fileMode: Int = 0o644
    ) throws(LMDBError) {
        // `MDB_env **` is annotated `counted_by: 1`, so the out-parameter is a
        // one-element MutableSpan rather than a pointer.
        var out = CollectionOfOne<MDB_env?>(nil)
        var outSpan = out.mutableSpan
        try check(MDB_env.create(&outSpan))
        let env = out[0]!

        do {
            try check(env.setMaxDatabases(MDB_dbi(maxDatabases)))
            if let maxReaders {
                try check(env.setMaxReaders(UInt32(maxReaders)))
            }
            try check(env.setMapSize(mdb_size_t(mapSize)))
            // MDB_NOTLS: read transactions are owned by the Swift value, not
            // by the thread, so they may be held across an `await`.
            let flags = options.rawValue | UInt32(MDB_NOTLS)
            try check(path.withCString { path in
                unsafe env.open(path: path, flags: flags, mode: mdb_mode_t(fileMode))
            })
        } catch {
            // mdb_env_open documents that a failed open still needs a close.
            env.close()
            throw error
        }
        self.raw = env
    }

    deinit { raw.close() }
}

/// Special options for opening an ``Environment``.
///
/// The ``changeable`` options (``noSync``, ``noMetaSync``, ``mapAsync`` and
/// ``noMemoryInit``) can also be turned on or off on an open environment with
/// ``Environment/setOptions(_:enabled:)``; the rest are fixed when it opens.
public struct EnvironmentOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Open the environment read-only (`MDB_RDONLY`).
    ///
    /// No write operations are allowed: ``WriteTransaction``s fail, and
    /// databases must be opened with
    /// ``Environment/existingDatabase(named:options:)``. LMDB still modifies
    /// the lock file, unless that is on a read-only filesystem.
    public static let readOnly = EnvironmentOptions(rawValue: UInt32(MDB_RDONLY))

    /// Use `path` as the name of the data file rather than of a directory to
    /// put it in (`MDB_NOSUBDIR`). The lock file is the same path with
    /// `-lock` appended.
    public static let noSubdirectory = EnvironmentOptions(rawValue: UInt32(MDB_NOSUBDIR))

    /// Don't flush system buffers to disk when committing (`MDB_NOSYNC`).
    ///
    /// Durability is then up to the operating system or
    /// ``Environment/sync(force:)``. A system crash can undo the last
    /// committed transactions, but integrity is kept, as long as the
    /// filesystem preserves write order, unless combined with ``writeMap``.
    public static let noSync = EnvironmentOptions(rawValue: UInt32(MDB_NOSYNC))

    /// Flush data but not the meta page when committing (`MDB_NOMETASYNC`).
    ///
    /// The meta page reaches disk with the next commit or
    /// ``Environment/sync(force:)``. A system crash can undo the last
    /// committed transaction, but keeps the database intact and consistent.
    public static let noMetaSync = EnvironmentOptions(rawValue: UInt32(MDB_NOMETASYNC))

    /// With ``writeMap``, flush asynchronously (`MDB_MAPASYNC`). As with
    /// ``noSync``, a system crash can undo the last committed transactions.
    public static let mapAsync = EnvironmentOptions(rawValue: UInt32(MDB_MAPASYNC))

    /// Use a writable memory map (`MDB_WRITEMAP`).
    ///
    /// Faster and uses fewer allocations, but a stray write through a bad
    /// pointer anywhere in the process can corrupt the database. Incompatible
    /// with nested transactions (``WriteTransaction/nested(_:)``).
    public static let writeMap = EnvironmentOptions(rawValue: UInt32(MDB_WRITEMAP))

    /// Don't do any locking (`MDB_NOLOCK`).
    ///
    /// The application must then ensure there is only one writer at a time,
    /// and that no reader is using old snapshots while a writer reuses their
    /// pages.
    public static let noLock = EnvironmentOptions(rawValue: UInt32(MDB_NOLOCK))

    /// Turn off readahead (`MDB_NORDAHEAD`). Most operating systems read ahead
    /// for memory-mapped files; turning that off can help random reads when
    /// the database is larger than RAM.
    public static let noReadAhead = EnvironmentOptions(rawValue: UInt32(MDB_NORDAHEAD))

    /// Don't initialize memory before writing it to disk (`MDB_NOMEMINIT`).
    ///
    /// Saves a `memset` per page, but unused parts of pages may then hold
    /// whatever the process's memory last contained, which ends up in the
    /// file. Has no effect with ``writeMap``.
    public static let noMemoryInit = EnvironmentOptions(rawValue: UInt32(MDB_NOMEMINIT))

    /// Open the previous meta page's snapshot rather than the latest
    /// (`MDB_PREVSNAPSHOT`), to roll back a bad last commit.
    public static let previousSnapshot = EnvironmentOptions(rawValue: UInt32(MDB_PREVSNAPSHOT))

    /// The options ``Environment/setOptions(_:enabled:)`` can change after the
    /// environment is open.
    public static let changeable: EnvironmentOptions = [.noSync, .noMetaSync, .mapAsync, .noMemoryInit]
}

// MARK: - Configuration

extension Environment {
    /// The options the environment is open with.
    ///
    /// Reflects later changes made with ``setOptions(_:enabled:)``.
    public var options: EnvironmentOptions {
        get throws(LMDBError) {
            var flags = CollectionOfOne<UInt32>(0)
            var flagsSpan = flags.mutableSpan
            try check(raw.getFlags(&flagsSpan))
            // MDB_NOTLS is always set by this wrapper; it is not an option.
            return EnvironmentOptions(rawValue: flags[0] & ~UInt32(MDB_NOTLS))
        }
    }

    /// Turns options on or off on the open environment.
    ///
    /// Calls are serialized, since LMDB leaves concurrent changes undefined.
    ///
    /// - Parameters:
    ///   - options: Options from ``EnvironmentOptions/changeable``.
    ///   - enabled: Whether to turn them on or off.
    /// - Throws: ``LMDBError`` (`EINVAL`) for options that can only be set
    ///   when opening.
    public func setOptions(_ options: EnvironmentOptions, enabled: Bool) throws(LMDBError) {
        // "If several threads change the flags at the same time, the result is
        // undefined." (mdb_env_set_flags)
        let rc = configurationLock.withLock { _ in
            raw.setFlags(options.rawValue, enabled: enabled ? 1 : 0)
        }
        try check(rc)
    }

    /// Changes the size of the memory map, which is the maximum size of the
    /// database.
    ///
    /// Typically called after a write fails with ``LMDBError/mapFull``. The
    /// new size takes effect immediately in this process, and reaches other
    /// processes with the next committed write; only increases are
    /// persisted. If another process grew the map, beginning a transaction
    /// fails with ``LMDBError/mapResized``: call this with `0` to adopt the
    /// new size.
    ///
    /// LMDB requires that no transaction is open in this process. Because
    /// every transaction borrows the environment and this method needs
    /// exclusive access, the compiler enforces that for transactions on this
    /// environment.
    ///
    /// - Parameter byteCount: The new size in bytes, ideally a multiple of the
    ///   OS page size, or `0` to adopt the size already in the file.
    public mutating func setMapSize(_ byteCount: Int) throws(LMDBError) {
        try check(raw.setMapSize(mdb_size_t(byteCount)))
    }

    /// The number of reader slots: how many read transactions may be open at
    /// once, across all processes using the environment.
    public var maxReaders: Int {
        get throws(LMDBError) {
            var readers = CollectionOfOne<UInt32>(0)
            var readersSpan = readers.mutableSpan
            try check(raw.getMaxReaders(&readersSpan))
            return Int(readers[0])
        }
    }

    /// The maximum size of a key, and of a value in a
    /// ``DatabaseOptions/duplicateSort`` database, in bytes.
    ///
    /// Depends on how LMDB was built and on the page size, so read it rather
    /// than assuming LMDB's usual default of 511. Longer keys fail with
    /// ``LMDBError/badValueSize``.
    public var maxKeySize: Int { Int(raw.maxKeySize) }
}

// MARK: - Databases

/// A handle to a database in an ``Environment``.
///
/// Get one from ``Environment/openDatabase(named:options:)`` or
/// ``Environment/existingDatabase(named:options:)``, typically once at
/// startup, and keep it: a handle is a plain `Sendable` value that stays
/// valid until its environment is closed, and can be used in any transaction
/// on that environment. It must not be used with another environment.
public struct Database: Hashable, Sendable {
    let handle: MDB_dbi

    /// The options the database was created with, as LMDB reports them
    /// (`mdb_dbi_flags`), which may differ from those passed when opening an
    /// existing database.
    public let options: DatabaseOptions
}

/// Special options for a database, fixed when it is created.
///
/// Pass them to ``Environment/openDatabase(named:options:)``; read them back
/// from ``Database/options``.
public struct DatabaseOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Allow several values per key, kept sorted (`MDB_DUPSORT`).
    ///
    /// Values are limited to ``Environment/maxKeySize`` bytes. Enables the
    /// duplicate operations of ``Cursor``, such as
    /// ``Cursor/nextDuplicate()``.
    public static let duplicateSort = DatabaseOptions(rawValue: UInt32(MDB_DUPSORT))

    /// With ``duplicateSort``, all values of a key have the same size
    /// (`MDB_DUPFIXED`).
    ///
    /// Stores them more compactly, and enables reading a page of them at a
    /// time with ``Cursor/duplicateBatch()``.
    public static let duplicateFixed = DatabaseOptions(rawValue: UInt32(MDB_DUPFIXED))

    /// Compare keys in reverse byte order, from the last byte to the first
    /// (`MDB_REVERSEKEY`).
    public static let reverseKey = DatabaseOptions(rawValue: UInt32(MDB_REVERSEKEY))

    /// With ``duplicateSort``, compare values in reverse byte order
    /// (`MDB_REVERSEDUP`).
    public static let reverseDuplicate = DatabaseOptions(rawValue: UInt32(MDB_REVERSEDUP))

    /// Keys are binary unsigned integers in native byte order, all `UInt32`
    /// or all `UInt` sized, and compare numerically (`MDB_INTEGERKEY`).
    ///
    /// Not needed with the integer conformances of ``LMDBEncodable``, whose
    /// big-endian encoding already sorts numerically under the default
    /// comparison, and not to be combined with them. See
    /// <doc:TypedKeysAndValues>.
    public static let integerKey = DatabaseOptions(rawValue: UInt32(MDB_INTEGERKEY))

    /// With ``duplicateFixed``, values are binary unsigned integers in native
    /// byte order (`MDB_INTEGERDUP`). The same caveat as ``integerKey``
    /// applies.
    public static let integerDuplicate = DatabaseOptions(rawValue: UInt32(MDB_INTEGERDUP))
}

extension Environment {
    /// Opens a database, creating it if it doesn't exist yet.
    ///
    /// Call it once per database, typically at startup, and keep the handle.
    /// Opening the same database again returns the same handle.
    ///
    /// Opens the database in a write transaction of its own, so it must not
    /// be called from a thread that is already inside a write transaction on
    /// this environment: that would deadlock.
    ///
    /// - Parameters:
    ///   - name: The database name, or `nil` for the main database. Named
    ///     databases count towards the environment's `maxDatabases`.
    ///   - options: The options to create the database with. An existing
    ///     database keeps its own; see ``Database/options``.
    /// - Returns: A handle usable in any later transaction on this
    ///   environment.
    /// - Throws: ``LMDBError/databasesFull`` if `maxDatabases` handles are
    ///   already open, or another ``LMDBError``, such as `EACCES` in a
    ///   ``EnvironmentOptions/readOnly`` environment.
    public func openDatabase(
        named name: String? = nil,
        options: DatabaseOptions = []
    ) throws(LMDBError) -> Database {
        try openingDatabases { (txn) throws(LMDBError) in
            try txn.openDatabase(named: name, flags: UInt32(MDB_CREATE) | options.rawValue)
        }
    }

    /// Opens a database if it exists, without creating it.
    ///
    /// Works on a ``EnvironmentOptions/readOnly`` environment, where it uses
    /// a read transaction; otherwise it uses a write transaction, like
    /// ``openDatabase(named:options:)``, and the same deadlock caveat
    /// applies.
    ///
    /// - Parameters:
    ///   - name: The database name, or `nil` for the main database.
    ///   - options: Options to check the database against. Usually empty:
    ///     the handle reports the database's own in ``Database/options``.
    /// - Returns: The handle, or `nil` if there is no database by that name.
    public func existingDatabase(
        named name: String? = nil,
        options: DatabaseOptions = []
    ) throws(LMDBError) -> Database? {
        try openingDatabases { (txn) throws(LMDBError) -> Database? in
            do throws(LMDBError) {
                return try txn.openDatabase(named: name, flags: options.rawValue)
            } catch .notFound {
                return nil
            }
        }
    }

    /// Runs `body` in a transaction that may open databases, then commits it,
    /// which is what makes the handles usable by every later transaction
    /// (aborting closes them, even in a read-only transaction).
    ///
    /// `mdb_dbi_open` "must not be called from multiple concurrent
    /// transactions in the same process", and a transaction that calls it
    /// "must finish (either commit or abort) before any other transaction in
    /// the process may use this function". In a read-write environment a
    /// write transaction gives that ordering through LMDB's writer lock; in a
    /// read-only one, where there are no writers, `configurationLock` does.
    /// Never both, so the two locks can't deadlock against each other.
    private func openingDatabases<Result>(
        _ body: (MDB_txn) throws(LMDBError) -> Result
    ) throws(LMDBError) -> Result {
        if try options.contains(.readOnly) {
            return try configurationLock.withLock { (_) throws(LMDBError) -> Result in
                let txn = try ReadTransaction(self)
                let result = try body(txn.raw)
                try txn.commitOpenedDatabases()
                return result
            }
        }
        let txn = try WriteTransaction(self)
        let result = try body(txn.raw)
        try txn.commit()
        return result
    }
}

extension MDB_txn {
    /// mdb_dbi_open, then mdb_dbi_flags to record the options LMDB actually
    /// uses, which for an existing database may differ from `flags`.
    func openDatabase(named name: String?, flags: UInt32) throws(LMDBError) -> Database {
        var out = CollectionOfOne<MDB_dbi>(0)
        var outSpan = out.mutableSpan
        if let name {
            try check(name.withCString { name in
                unsafe openDatabase(name: name, flags: flags, &outSpan)
            })
        } else {
            try check(unsafe openDatabase(name: nil, flags: flags, &outSpan))
        }
        let handle = out[0]

        var stored = CollectionOfOne<UInt32>(0)
        var storedSpan = stored.mutableSpan
        try check(databaseFlags(handle, &storedSpan))
        return Database(handle: handle, options: DatabaseOptions(rawValue: stored[0]))
    }
}

// MARK: - Transactions

extension Environment {
    /// Runs `body` in a read-only transaction.
    ///
    /// The transaction sees a consistent snapshot of the data as of when it
    /// began, unaffected by later commits. Values read inside `body` point
    /// straight into the memory map, and the compiler rejects any attempt to
    /// let one outlive the transaction.
    ///
    /// Keep read transactions short: while one is open, LMDB can't reuse the
    /// pages its snapshot needs, so under heavy writing the file grows.
    ///
    /// - Parameter body: The work to do. It receives the transaction
    ///   borrowed, so it can't keep it.
    /// - Returns: What `body` returns.
    /// - Throws: An ``LMDBError`` if the transaction can't begin (for example
    ///   ``LMDBError/readersFull``), or whatever `body` throws.
    public func read<Result: ~Copyable, Failure: Error>(
        _ body: (borrowing ReadTransaction) throws(Failure) -> Result
    ) throws -> Result {
        let txn = try ReadTransaction(self)
        return try body(txn)
    }

    /// Runs `body` in a read-write transaction, committing it if `body`
    /// returns and aborting it if `body` throws.
    ///
    /// There is one writer at a time per environment: if another write
    /// transaction is open, in this process or another, this waits for it to
    /// end. Calling it from a thread that is already inside a write
    /// transaction on this environment deadlocks; use
    /// ``WriteTransaction/nested(_:)`` for a transaction inside a
    /// transaction.
    ///
    /// Unlike ``WriteTransaction/init(_:)``, this can be called from async
    /// code: `body` is synchronous, so LMDB's writer lock can't be held
    /// across an `await`.
    ///
    /// - Parameter body: The work to do. It receives the transaction `inout`.
    /// - Returns: What `body` returns.
    /// - Throws: An ``LMDBError`` if the transaction can't begin or commit
    ///   (for example ``LMDBError/mapFull``), or whatever `body` throws, in
    ///   which case nothing is written.
    public func write<Result: ~Copyable, Failure: Error>(
        _ body: (inout WriteTransaction) throws(Failure) -> Result
    ) throws -> Result {
        var txn = try WriteTransaction(self)
        // If `body` throws, `txn` is dropped and its deinit aborts.
        let result = try body(&txn)
        try txn.commit()
        return result
    }
}

extension MDB_env {
    func beginTransaction(parent: MDB_txn? = nil, flags: UInt32) throws(LMDBError) -> MDB_txn {
        var out = CollectionOfOne<MDB_txn?>(nil)
        var outSpan = out.mutableSpan
        try check(beginTransaction(parent: parent, flags: flags, &outSpan))
        return out[0]!
    }
}

// MARK: - Version

/// The version string of the linked LMDB library, such as
/// `"LMDB 0.9.70: (December 19, 2015)"`.
public var lmdbVersionString: String {
    // `mdb_version` accepts NULL for each number, but the annotations make
    // them non-optional spans; the numbers are simply discarded.
    var major = CollectionOfOne<Int32>(0)
    var minor = CollectionOfOne<Int32>(0)
    var patch = CollectionOfOne<Int32>(0)
    var majorSpan = major.mutableSpan
    var minorSpan = minor.mutableSpan
    var patchSpan = patch.mutableSpan
    // A static string inside the library.
    return unsafe String(cString: mdb_version(major: &majorSpan, minor: &minorSpan, patch: &patchSpan))
}

/// The version of the linked LMDB library, as numbers.
public var lmdbVersion: (major: Int, minor: Int, patch: Int) {
    var major = CollectionOfOne<Int32>(0)
    var minor = CollectionOfOne<Int32>(0)
    var patch = CollectionOfOne<Int32>(0)
    var majorSpan = major.mutableSpan
    var minorSpan = minor.mutableSpan
    var patchSpan = patch.mutableSpan
    // Still `unsafe` despite the Span overload: the returned `char *` is a
    // static description string, which we discard.
    _ = unsafe mdb_version(major: &majorSpan, minor: &minorSpan, patch: &patchSpan)
    return (Int(major[0]), Int(minor[0]), Int(patch[0]))
}
