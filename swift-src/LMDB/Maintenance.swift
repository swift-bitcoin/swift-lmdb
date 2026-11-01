import CLMDBInterop
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Statistics for a single database's B-tree in an environment (`MDB_stat`).
///
/// Retrieve these with ``ReadTransaction/statistics(for:)``,
/// ``WriteTransaction/statistics(for:)``, ``Environment/statistics(for:)``, or
/// ``Environment/statistics`` for the main database.
public struct DatabaseStatistics: Hashable, Sendable {
    /// Size of a database page in bytes (`ms_psize`).
    ///
    /// Currently the same for every database in an ``Environment``.
    public let pageSize: Int
    /// Depth (height) of the B-tree (`ms_depth`).
    public let depth: Int
    /// Number of internal (non-leaf) pages (`ms_branch_pages`).
    public let branchPages: Int
    /// Number of leaf pages (`ms_leaf_pages`).
    public let leafPages: Int
    /// Number of overflow pages, holding values too large to fit in a leaf
    /// page (`ms_overflow_pages`).
    public let overflowPages: Int
    /// Number of data items (`ms_entries`): key/value pairs, counting every
    /// value of a duplicate key.
    public let entries: Int

    /// Total number of pages in use by this database (`branchPages +
    /// leafPages + overflowPages`).
    public var totalPages: Int { branchPages + leafPages + overflowPages }

    init(_ stat: MDB_stat) {
        pageSize = Int(stat.ms_psize)
        depth = Int(stat.ms_depth)
        branchPages = Int(stat.ms_branch_pages)
        leafPages = Int(stat.ms_leaf_pages)
        overflowPages = Int(stat.ms_overflow_pages)
        entries = Int(stat.ms_entries)
    }
}

/// Information about the state of an ``Environment`` as a whole
/// (`MDB_envinfo`).
///
/// Retrieve this with ``Environment/info``.
public struct EnvironmentInfo: Hashable, Sendable {
    /// Size of the data memory map in bytes (`me_mapsize`), the upper bound on
    /// the database file size.
    public let mapSize: Int
    /// ID of the last used page in the file (`me_last_pgno`);
    /// `(lastPageNumber + 1) * pageSize` is roughly how much of the map is in
    /// use.
    public let lastPageNumber: Int
    /// ID of the last committed write transaction (`me_last_txnid`).
    public let lastTransactionID: Int
    /// Number of reader slots allocated in the lock file (`me_maxreaders`).
    public let maxReaders: Int
    /// Maximum number of reader slots that have been used simultaneously
    /// (`me_numreaders`).
    ///
    /// Slots are reused when read transactions end, so this is a high-water
    /// mark rather than the number of currently open read transactions.
    public let readersUsed: Int

    init(_ info: MDB_envinfo) {
        mapSize = Int(info.me_mapsize)
        lastPageNumber = Int(info.me_last_pgno)
        lastTransactionID = Int(info.me_last_txnid)
        maxReaders = Int(info.me_maxreaders)
        readersUsed = Int(info.me_numreaders)
    }
}

// MARK: - Statistics

extension ReadTransaction {
    /// Returns B-tree statistics for `database` as of this transaction's
    /// snapshot (`mdb_stat`).
    ///
    /// - Parameter database: The database to inspect.
    /// - Returns: The database's page and entry counts.
    public func statistics(for database: Database) throws(LMDBError) -> DatabaseStatistics {
        try raw.statistics(for: database)
    }

    /// Returns the number of entries in `database`, counting every value of a
    /// duplicate key (`mdb_stat`).
    ///
    /// Constant time: LMDB maintains the entry count in the database header.
    ///
    /// - Parameter database: The database to count.
    /// - Returns: The number of key/value pairs in `database`.
    public func count(in database: Database) throws(LMDBError) -> Int {
        try statistics(for: database).entries
    }
}

extension WriteTransaction {
    /// Returns B-tree statistics for `database`, including this transaction's
    /// own uncommitted changes (`mdb_stat`).
    ///
    /// - Parameter database: The database to inspect.
    /// - Returns: The database's page and entry counts.
    public func statistics(for database: Database) throws(LMDBError) -> DatabaseStatistics {
        try raw.statistics(for: database)
    }

    /// Returns the number of entries in `database`, including this
    /// transaction's own uncommitted changes (`mdb_stat`).
    ///
    /// Constant time: LMDB maintains the entry count in the database header.
    ///
    /// - Parameter database: The database to count.
    /// - Returns: The number of key/value pairs in `database`.
    public func count(in database: Database) throws(LMDBError) -> Int {
        try statistics(for: database).entries
    }
}

extension MDB_txn {
    fileprivate func statistics(for database: Database) throws(LMDBError) -> DatabaseStatistics {
        var stat = CollectionOfOne(MDB_stat())
        var statSpan = stat.mutableSpan
        try check(statistics(database.handle, &statSpan))
        return DatabaseStatistics(stat[0])
    }
}

extension Environment {
    /// Returns B-tree statistics for `database` in a short-lived read
    /// transaction (`mdb_stat`).
    ///
    /// - Parameter database: The database to inspect.
    /// - Returns: The database's page and entry counts.
    public func statistics(for database: Database) throws(LMDBError) -> DatabaseStatistics {
        let txn = try ReadTransaction(self)
        return try txn.statistics(for: database)
    }

    /// Statistics for the main (unnamed) database (`mdb_env_stat`), which also
    /// stores the directory of named databases.
    public var statistics: DatabaseStatistics {
        get throws(LMDBError) {
            var stat = CollectionOfOne(MDB_stat())
            var statSpan = stat.mutableSpan
            try check(raw.statistics(&statSpan))
            return DatabaseStatistics(stat[0])
        }
    }

    /// Information about the environment (`mdb_env_info`): map size, last used
    /// page, last transaction ID, and reader slot usage.
    public var info: EnvironmentInfo {
        get throws(LMDBError) {
            var info = CollectionOfOne(MDB_envinfo())
            var infoSpan = info.mutableSpan
            try check(raw.info(&infoSpan))
            return EnvironmentInfo(info[0])
        }
    }

    /// The directory or file path that was used to open this environment
    /// (`mdb_env_get_path`).
    public var path: String {
        get throws(LMDBError) {
            var path: UnsafePointer<CChar>? = nil
            try check(unsafe raw.getPath(&path))
            // LMDB owns the string, for as long as the environment is open.
            return unsafe String(cString: path!)
        }
    }

    /// Returns the names of the named databases in the environment.
    ///
    /// LMDB records named databases as entries in the main (unnamed) database.
    /// If you also store your own key/value pairs in the main database, any of
    /// their keys that are valid UTF-8 will appear in this list as well.
    public func databaseNames() throws(LMDBError) -> [String] {
        // Opened through `existingDatabase`, which serializes mdb_dbi_open.
        guard let main = try existingDatabase() else { return [] }
        let txn = try ReadTransaction(self)
        let cursor = try Cursor(txn, database: main)
        var names: [String] = []
        while let entry = try cursor.next() {
            if let name = try? entry.key(as: String.self) { names.append(name) }
        }
        return names
    }
}

// MARK: - Durability and backups

extension Environment {
    /// Flushes the environment's data buffers to disk (`mdb_env_sync`).
    ///
    /// Data is always written to disk when ``WriteTransaction/commit()`` is
    /// called, unless the environment was opened with
    /// ``EnvironmentOptions/noSync`` or ``EnvironmentOptions/mapAsync``.
    ///
    /// - Parameter force: If `true` (the default), forces a synchronous flush.
    ///   Otherwise, if the environment has ``EnvironmentOptions/noSync``, the
    ///   flush is skipped, and if it has ``EnvironmentOptions/mapAsync``, the
    ///   flush is scheduled asynchronously.
    /// - Throws: ``LMDBError`` (`EACCES`) on a
    ///   ``EnvironmentOptions/readOnly`` environment, or `EIO` on an I/O
    ///   failure.
    public func sync(force: Bool = true) throws(LMDBError) {
        try check(raw.sync(force: force ? 1 : 0))
    }

    /// Copies the environment to `path`, producing a consistent hot backup
    /// while other transactions continue to run (`mdb_env_copy2`).
    ///
    /// No lock file is created at the destination, since LMDB recreates it
    /// when the copy is opened.
    ///
    /// > Note: This call holds a read-only transaction for the duration of the
    /// > copy, which can cause significant file size growth if run in parallel
    /// > with heavy write transactions.
    ///
    /// - Parameters:
    ///   - path: The destination directory, which must already exist and be
    ///     empty. For an environment opened with
    ///     ``EnvironmentOptions/noSubdirectory``, the destination file path
    ///     instead, which must not exist yet.
    ///   - compact: If `true`, omits free pages and sequentially renumbers the
    ///     remaining pages in output (`MDB_CP_COMPACT`). This consumes more
    ///     CPU and runs more slowly than the default raw copy, especially if
    ///     the environment has suffered a lot of page churn.
    public func copy(to path: String, compact: Bool = false) throws(LMDBError) {
        let flags = compact ? UInt32(MDB_CP_COMPACT) : 0
        try check(path.withCString { path in
            unsafe raw.copy(to: path, flags: flags)
        })
    }

    #if !os(Windows)
    /// Copies the environment to an open file descriptor, such as a pipe or
    /// socket for streaming a hot backup (`mdb_env_copyfd2`).
    ///
    /// > Note: This call holds a read-only transaction for the duration of the
    /// > copy, which can cause significant file size growth if run in parallel
    /// > with heavy write transactions.
    ///
    /// - Parameters:
    ///   - fileDescriptor: An open file descriptor with write access. LMDB
    ///     does not close it when finished.
    ///   - compact: If `true`, omits free pages and sequentially renumbers the
    ///     remaining pages (`MDB_CP_COMPACT`).
    public func copy(toFileDescriptor fileDescriptor: Int32, compact: Bool = false) throws(LMDBError) {
        let flags = compact ? UInt32(MDB_CP_COMPACT) : 0
        try check(raw.copy(toFileDescriptor: fileDescriptor, flags: flags))
    }
    #endif

    /// Checks for stale entries in the reader lock table and frees any slots
    /// left behind by processes that terminated without closing their read
    /// transactions (`mdb_reader_check`).
    ///
    /// Worth calling at startup after a crash: stale reader slots prevent LMDB
    /// from reusing the pages pinned by their snapshots, causing the data file
    /// to grow until those slots are cleared.
    ///
    /// - Returns: The number of stale reader slots that were cleared.
    @discardableResult
    public func clearStaleReaders() throws(LMDBError) -> Int {
        var dead = CollectionOfOne<Int32>(0)
        var deadSpan = dead.mutableSpan
        try check(raw.checkReaders(&deadSpan))
        return Int(dead[0])
    }
}

// MARK: - Introspection

extension Environment {
    #if !os(Windows)
    /// The file descriptor for the environment's data file (`mdb_env_get_fd`).
    ///
    /// For inspection only, such as `fstat`. LMDB owns the descriptor: do not
    /// close it, write to it, or change its flags.
    public var fileDescriptor: Int32 {
        get throws(LMDBError) {
            var fd = CollectionOfOne<Int32>(-1)
            var fdSpan = fd.mutableSpan
            try check(raw.getFileDescriptor(&fdSpan))
            return fd[0]
        }
    }
    #endif

    /// Dumps the entries in the reader lock table as human-readable lines
    /// (`mdb_reader_list`).
    ///
    /// Returns a header line followed by the process ID, thread ID and
    /// transaction ID of each active reader across all processes, or a single
    /// `"(no active readers)"` line if none are open.
    public func readerList() throws(LMDBError) -> [String] {
        var lines: [String] = []
        // The callback is a C function pointer with no captures; `lines`
        // reaches it as the context pointer, valid for the call's duration.
        let rc = withUnsafeMutablePointer(to: &lines) { lines in
            unsafe raw.listReaders({ message, context in
                guard let message = unsafe message, let context = unsafe context else { return -1 }
                let line = unsafe String(cString: message)
                // Each message is one line, including its newline.
                let trimmed = line.hasSuffix("\n") ? String(line.dropLast()) : line
                unsafe context.assumingMemoryBound(to: [String].self).pointee.append(trimmed)
                return 0
            }, context: UnsafeMutableRawPointer(lines))
        }
        // Documented as "< 0 on failure, >= 0 on success".
        guard rc >= 0 else { throw LMDBError(code: rc) }
        return lines
    }
}

// MARK: - Comparing with a database's order

extension ReadTransaction {
    /// Compares two byte spans as keys according to `database`'s key
    /// comparison function (`mdb_cmp`).
    ///
    /// By default this is lexicographical byte order, reversed with
    /// ``DatabaseOptions/reverseKey`` or native-endian integer order with
    /// ``DatabaseOptions/integerKey``.
    ///
    /// - Parameters:
    ///   - a: The first key to compare.
    ///   - b: The second key to compare.
    ///   - database: The database whose key comparator to use.
    /// - Returns: How `a` orders relative to `b` in `database`.
    /// - Throws: ``LMDBError/badValueSize`` if `database` uses
    ///   ``DatabaseOptions/integerKey`` and `a` and `b` are not both 4 bytes
    ///   or both 8 bytes.
    public func compareKeys(_ a: RawSpan, _ b: RawSpan, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: false)
    }

    /// Compares two byte spans as duplicate values according to `database`'s
    /// duplicate value comparison function (`mdb_dcmp`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases.
    ///
    /// - Parameters:
    ///   - a: The first value to compare.
    ///   - b: The second value to compare.
    ///   - database: The ``DatabaseOptions/duplicateSort`` database whose
    ///     duplicate comparator to use.
    /// - Returns: How `a` orders relative to `b` among a key's values in
    ///   `database`.
    /// - Throws: ``LMDBError/incompatible`` if `database` was not opened with
    ///   ``DatabaseOptions/duplicateSort``, or ``LMDBError/badValueSize`` if
    ///   it uses ``DatabaseOptions/integerDuplicate`` and `a` and `b` are not
    ///   both 4 bytes or both 8 bytes.
    public func compareValues(_ a: RawSpan, _ b: RawSpan, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: true)
    }

    /// Compares two typed keys according to `database`'s key comparison
    /// function (`mdb_cmp`).
    ///
    /// See ``compareKeys(_:_:in:)-(RawSpan,RawSpan,_)``.
    public func compareKeys(_ a: some LMDBEncodable, _ b: some LMDBEncodable, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: false)
    }

    /// Compares two typed duplicate values according to `database`'s duplicate
    /// value comparison function (`mdb_dcmp`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases. See
    /// ``compareValues(_:_:in:)-(RawSpan,RawSpan,_)``.
    public func compareValues(_ a: some LMDBEncodable, _ b: some LMDBEncodable, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: true)
    }
}

extension WriteTransaction {
    /// Compares two byte spans as keys according to `database`'s key
    /// comparison function (`mdb_cmp`).
    ///
    /// See ``ReadTransaction/compareKeys(_:_:in:)-(RawSpan,RawSpan,_)``.
    public func compareKeys(_ a: RawSpan, _ b: RawSpan, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: false)
    }

    /// Compares two byte spans as duplicate values according to `database`'s
    /// duplicate value comparison function (`mdb_dcmp`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases. See
    /// ``ReadTransaction/compareValues(_:_:in:)-(RawSpan,RawSpan,_)``.
    public func compareValues(_ a: RawSpan, _ b: RawSpan, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: true)
    }

    /// Compares two typed keys according to `database`'s key comparison
    /// function (`mdb_cmp`).
    ///
    /// See ``ReadTransaction/compareKeys(_:_:in:)-(RawSpan,RawSpan,_)``.
    public func compareKeys(_ a: some LMDBEncodable, _ b: some LMDBEncodable, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: false)
    }

    /// Compares two typed duplicate values according to `database`'s duplicate
    /// value comparison function (`mdb_dcmp`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases. See
    /// ``ReadTransaction/compareValues(_:_:in:)-(RawSpan,RawSpan,_)``.
    public func compareValues(_ a: some LMDBEncodable, _ b: some LMDBEncodable, in database: Database) throws(LMDBError) -> ComparisonResult {
        try raw.compare(a, b, in: database, duplicates: true)
    }
}

extension MDB_txn {
    fileprivate func compare(
        _ a: some LMDBEncodable,
        _ b: some LMDBEncodable,
        in database: Database,
        duplicates: Bool
    ) throws(LMDBError) -> ComparisonResult {
        try a.withEncodedBytes { (a) throws(LMDBError) in
            try b.withEncodedBytes { (b) throws(LMDBError) in
                try compare(a, b, in: database, duplicates: duplicates)
            }
        }
    }

    /// mdb_cmp / mdb_dcmp, after the checks that keep them in bounds.
    ///
    /// - mdb_dcmp calls the database's value comparator, which LMDB leaves
    ///   NULL without MDB_DUPSORT: calling it would jump to address zero.
    /// - The integer comparators (MDB_INTEGERKEY / MDB_INTEGERDUP) read both
    ///   values using the *first* one's size, so different sizes would read
    ///   past the end of the shorter one.
    fileprivate func compare(
        _ a: RawSpan,
        _ b: RawSpan,
        in database: Database,
        duplicates: Bool
    ) throws(LMDBError) -> ComparisonResult {
        if duplicates {
            guard database.options.contains(.duplicateSort) else { throw .incompatible }
        }
        let integer: DatabaseOptions = duplicates ? .integerDuplicate : .integerKey
        if database.options.contains(integer) {
            guard a.byteCount == b.byteCount, a.byteCount == 4 || a.byteCount == 8 else {
                throw .badValueSize
            }
        }
        let order = a.withMDBVal { a in
            b.withMDBVal { b in
                // `const MDB_val *` with `counted_by: 1`: read-only Span overloads.
                let x = CollectionOfOne(a)
                let y = CollectionOfOne(b)
                return duplicates
                    ? compareDuplicates(database.handle, x.span, y.span)
                    : compare(database.handle, x.span, y.span)
            }
        }
        return order < 0 ? .orderedAscending : order > 0 ? .orderedDescending : .orderedSame
    }
}
