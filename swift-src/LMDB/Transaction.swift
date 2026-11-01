import CLMDBInterop

/// A read-only transaction: a consistent snapshot of an ``Environment``.
///
/// A read transaction sees the data as of when it began, unaffected by
/// writes committed afterwards, by this process or others. Readers never
/// block writers or other readers.
///
/// Usually you get one from ``Environment/read(_:)``. Creating one directly
/// keeps it open across several steps, or across an `await`:
///
/// ```swift
/// let snapshot = try ReadTransaction(env)
/// let a = try snapshot.value(forKey: "a", in: db, as: Int.self)
/// await somethingElse()
/// let b = try snapshot.value(forKey: "b", in: db, as: Int.self)   // same snapshot
/// ```
///
/// A read transaction is:
/// - **Non-copyable**, so it ends exactly once: when it goes out of scope, or
///   with ``reset()``.
/// - **Non-escapable**: its lifetime depends on a borrow of the environment,
///   so the environment can't close while it's open, and it can't be stored
///   anywhere that outlives that borrow.
/// - **Not `Sendable`**: LMDB allows a transaction to be used by one thread
///   at a time. It may still move between threads across an `await`, since
///   the wrapper opens environments with `MDB_NOTLS`.
///
/// Keep read transactions short. While one is open, LMDB can't reuse the
/// pages its snapshot needs, so under heavy writing the file grows.
public struct ReadTransaction: ~Copyable, ~Escapable {
    let raw: MDB_txn

    /// Begins a read-only transaction on `environment`.
    ///
    /// - Parameter environment: The environment to read, which stays borrowed
    ///   for as long as the transaction is open.
    /// - Throws: ``LMDBError/readersFull`` if every reader slot is in use, or
    ///   ``LMDBError/mapResized`` if another process grew the map.
    @_lifetime(borrow environment)
    public init(_ environment: borrowing Environment) throws(LMDBError) {
        raw = try environment.raw.beginTransaction(flags: UInt32(MDB_RDONLY))
    }

    @_lifetime(immortal)
    fileprivate init(raw: MDB_txn) {
        self.raw = raw
    }

    // A read-only transaction has nothing to commit; aborting just releases
    // its reader slot.
    deinit { raw.abort() }

    /// The ID of the snapshot this transaction reads: that of the last write
    /// transaction committed before it began.
    public var id: Int { Int(raw.id) }

    /// Ends the snapshot but keeps the transaction's resources for reuse
    /// (`mdb_txn_reset`).
    ///
    /// Releases the snapshot like ending the transaction would, so LMDB can
    /// reuse its pages, but keeps the allocation and reader slot, so
    /// ``ResetReadTransaction/renew()`` can start a new snapshot cheaply.
    /// Worth it for frequent short reads, such as serving requests:
    ///
    /// ```swift
    /// var txn = try ReadTransaction(env)
    /// while running {
    ///     try handle(txn)
    ///     let idle = txn.reset()
    ///     await nextRequest()
    ///     txn = try idle.renew()
    /// }
    /// ```
    ///
    /// This consumes the transaction, so the compiler rejects it while a
    /// value or ``Cursor`` from the old snapshot is still in use.
    ///
    /// - Returns: The reset transaction, which depends on the same
    ///   environment borrow.
    @_lifetime(copy self)
    public consuming func reset() -> ResetReadTransaction {
        let raw = self.raw
        let reset = unsafe _overrideLifetime(ResetReadTransaction(raw: raw), copying: self)
        discard self
        raw.reset()
        return reset
    }

    /// Ends the transaction by committing it, which for a read-only one only
    /// matters for keeping database handles opened in it.
    consuming func commitOpenedDatabases() throws(LMDBError) {
        let raw = self.raw
        discard self
        try check(raw.commit())
    }

    /// The bytes stored for `key` (`mdb_get`), without copying them.
    ///
    /// The span points into LMDB's memory map. It is valid for as long as the
    /// transaction, which the compiler enforces, and is read-only. In a
    /// ``DatabaseOptions/duplicateSort`` database this is the key's first
    /// value; use a ``Cursor`` for the others.
    ///
    /// - Parameters:
    ///   - key: The key to look up.
    ///   - database: The database to look in.
    /// - Returns: The value's bytes, or `nil` if the key isn't there.
    @_lifetime(borrow self)
    public func value(forKey key: RawSpan, in database: Database) throws(LMDBError) -> RawSpan? {
        let value = try raw.value(forKey: key, in: database)
        return unsafe _overrideLifetime(value, borrowing: self)
    }

    /// A copy of the bytes stored for `key`, for when they must outlive the
    /// transaction.
    ///
    /// - Parameters:
    ///   - key: The key to look up.
    ///   - database: The database to look in.
    /// - Returns: The value's bytes, or `nil` if the key isn't there.
    public func bytes(forKey key: RawSpan, in database: Database) throws(LMDBError) -> [UInt8]? {
        // Not `Optional.map`: it does not accept a non-escapable RawSpan.
        guard let value = try raw.value(forKey: key, in: database) else { return nil }
        return [UInt8](value)
    }
}

/// A read-only transaction that has been reset, ready for reuse.
///
/// It holds no snapshot, so it doesn't keep any pages alive. It can only be
/// renewed into a new ``ReadTransaction`` with ``renew()``, or dropped, which
/// frees it. Get one from ``ReadTransaction/reset()``.
///
/// Like the transaction it came from, it is non-copyable and depends on a
/// borrow of the environment.
public struct ResetReadTransaction: ~Copyable, ~Escapable {
    let raw: MDB_txn

    @_lifetime(immortal)
    fileprivate init(raw: MDB_txn) {
        self.raw = raw
    }

    // Freeing a reset transaction is still `mdb_txn_abort`.
    deinit { raw.abort() }

    /// Starts a new snapshot of the latest committed data (`mdb_txn_renew`).
    ///
    /// - Returns: A read transaction reusing this one's resources.
    /// - Throws: ``LMDBError`` if the snapshot can't begin, for example
    ///   ``LMDBError/mapResized``. The transaction is freed either way.
    @_lifetime(copy self)
    public consuming func renew() throws(LMDBError) -> ReadTransaction {
        let raw = self.raw
        let rc = raw.renew()
        guard rc == MDB_SUCCESS else {
            // Every exit must end `self` when one uses `discard self`.
            discard self
            raw.abort()
            throw LMDBError(code: rc)
        }
        let renewed = unsafe _overrideLifetime(ReadTransaction(raw: raw), copying: self)
        discard self
        return renewed
    }
}

/// A read-write transaction on an ``Environment``.
///
/// Changes become visible to other transactions, and durable, only when
/// ``commit()`` succeeds. Until then they are visible only to this
/// transaction, and ``abort()`` (or simply dropping it) discards them.
///
/// Usually you get one from ``Environment/write(_:)``, which commits when its
/// closure returns. Creating one directly lets you decide whether to commit:
///
/// ```swift
/// var txn = try WriteTransaction(env)
/// try txn.put(order, forKey: id, in: orders)
/// if try txn.count(in: orders) <= limit {
///     try txn.commit()
/// } // otherwise dropped, and so aborted
/// ```
///
/// There is one write transaction at a time per environment, across all
/// processes; beginning another waits until it ends.
///
/// A write transaction is:
/// - **Non-copyable**, so it ends exactly once. ``commit()`` and ``abort()``
///   consume it, so it can't be used afterwards; dropping it aborts.
/// - **Non-escapable**: its lifetime depends on a borrow of the environment.
/// - **Exclusive while writing**: reads borrow it, writes are `mutating`.
///   Since values returned by reads borrow the transaction, the compiler
///   stops a write while one is still in use, which matters because LMDB
///   invalidates them on the next write.
public struct WriteTransaction: ~Copyable, ~Escapable {
    let raw: MDB_txn
    /// Kept to begin nested transactions, which LMDB starts from the
    /// environment with this transaction as the parent.
    let environment: MDB_env

    /// Begins a write transaction on `environment`, waiting until any other
    /// one has ended.
    ///
    /// Unavailable from async code: LMDB's writer lock belongs to the thread
    /// that took it, and a transaction held across an `await` could be
    /// committed from another thread. Use ``Environment/write(_:)``, whose
    /// closure is synchronous, instead.
    ///
    /// Beginning a second write transaction on a thread that already holds
    /// one deadlocks, as it does in C. For a transaction inside a transaction,
    /// use ``nested(_:)``.
    ///
    /// - Parameter environment: The environment to write, which stays
    ///   borrowed for as long as the transaction is open.
    /// - Throws: ``LMDBError``, such as `EACCES` in a
    ///   ``EnvironmentOptions/readOnly`` environment.
    @available(*, noasync, message: "use Environment.write from async code")
    @_lifetime(borrow environment)
    public init(_ environment: borrowing Environment) throws(LMDBError) {
        raw = try environment.raw.beginTransaction(flags: 0)
        self.environment = environment.raw
    }

    @_lifetime(immortal)
    private init(raw: MDB_txn, environment: MDB_env) {
        self.raw = raw
        self.environment = environment
    }

    /// A child transaction, with exclusive access to its parent while open.
    @_lifetime(&parent)
    private init(nestedIn parent: inout WriteTransaction) throws(LMDBError) {
        let child = WriteTransaction(
            raw: try parent.environment.beginTransaction(parent: parent.raw, flags: 0),
            environment: parent.environment)
        self = unsafe _overrideLifetime(child, mutating: &parent)
    }

    deinit { raw.abort() }

    /// The ID this transaction will have once committed: one more than the
    /// last committed transaction's.
    public var id: Int { Int(raw.id) }

    /// Commits all of the transaction's changes to the database
    /// (`mdb_txn_commit`).
    ///
    /// The transaction is consumed, and freed, even if the commit fails.
    ///
    /// - Throws: ``LMDBError`` if the changes can't be written, for example
    ///   `ENOSPC` (no more disk space) or `EIO`. Nothing is committed then.
    public consuming func commit() throws(LMDBError) {
        let raw = self.raw
        discard self
        try check(raw.commit())
    }

    /// Discards all of the transaction's changes (`mdb_txn_abort`).
    ///
    /// The same as dropping the transaction, but explicit.
    public consuming func abort() {}

    /// Runs `body` in a nested transaction: a savepoint inside this one.
    ///
    /// The child sees this transaction's changes. If `body` returns, the
    /// child's changes become part of this transaction; if it throws, they
    /// are discarded and this transaction carries on as before. Either way
    /// they reach the database only if this transaction commits. Nested
    /// transactions can themselves be nested.
    ///
    /// ```swift
    /// try env.write { txn in
    ///     try txn.put(header, forKey: id, in: headers)
    ///     try? txn.nested { attempt in
    ///         try attempt.put(body, forKey: id, in: bodies)
    ///         try validate(attempt)   // throwing undoes only the body
    ///     }
    /// }
    /// ```
    ///
    /// While the child is open it has exclusive access to this transaction,
    /// which LMDB requires. Not supported with
    /// ``EnvironmentOptions/writeMap``.
    ///
    /// Closure-only by design: see <doc:Safety>.
    ///
    /// - Parameter body: The work to do in the child transaction.
    /// - Returns: What `body` returns.
    /// - Throws: An ``LMDBError`` if the child can't begin or commit, or
    ///   whatever `body` throws.
    public mutating func nested<Result: ~Copyable, Failure: Error>(
        _ body: (inout WriteTransaction) throws(Failure) -> Result
    ) throws -> Result {
        var child = try WriteTransaction(nestedIn: &self)
        // If `body` throws, `child` is dropped and its deinit aborts.
        let result = try body(&child)
        try child.commit()
        return result
    }

    // MARK: Reading

    /// The bytes stored for `key` (`mdb_get`), without copying them,
    /// including this transaction's own changes.
    ///
    /// The span is valid until the next write in this transaction, which the
    /// compiler enforces, and is read-only. In a
    /// ``DatabaseOptions/duplicateSort`` database this is the key's first
    /// value.
    ///
    /// - Parameters:
    ///   - key: The key to look up.
    ///   - database: The database to look in.
    /// - Returns: The value's bytes, or `nil` if the key isn't there.
    @_lifetime(borrow self)
    public func value(forKey key: RawSpan, in database: Database) throws(LMDBError) -> RawSpan? {
        let value = try raw.value(forKey: key, in: database)
        return unsafe _overrideLifetime(value, borrowing: self)
    }

    /// A copy of the bytes stored for `key`, for when they must outlive the
    /// transaction or a later write.
    public func bytes(forKey key: RawSpan, in database: Database) throws(LMDBError) -> [UInt8]? {
        // Not `Optional.map`: it does not accept a non-escapable RawSpan.
        guard let value = try raw.value(forKey: key, in: database) else { return nil }
        return [UInt8](value)
    }

    // MARK: Writing

    /// Stores a key/value pair (`mdb_put`).
    ///
    /// By default, replaces the key's value, or in a
    /// ``DatabaseOptions/duplicateSort`` database adds `value` to the key's
    /// values. See ``PutOptions`` for the alternatives.
    ///
    /// - Parameters:
    ///   - value: The bytes to store. They are copied into the database.
    ///   - key: The key, between 1 and ``Environment/maxKeySize`` bytes.
    ///   - database: The database to store in.
    ///   - options: How to store it.
    /// - Throws: ``LMDBError/keyExists`` when `options` forbid replacing or
    ///   duplicating, ``LMDBError/mapFull``, ``LMDBError/badValueSize``, or
    ///   another ``LMDBError``.
    public mutating func put(
        _ value: RawSpan,
        forKey key: RawSpan,
        in database: Database,
        options: PutOptions = []
    ) throws(LMDBError) {
        try key.withMDBVal { (keyVal) throws(LMDBError) in
            try value.withMDBVal { (dataVal) throws(LMDBError) in
                // `MDB_val *` is annotated `counted_by: 1`: the one-element
                // MutableSpan overload instead of a pointer.
                var k = CollectionOfOne(keyVal)
                var d = CollectionOfOne(dataVal)
                var kSpan = k.mutableSpan
                var dSpan = d.mutableSpan
                try check(raw.put(database.handle, key: &kSpan, data: &dSpan, flags: options.rawValue))
            }
        }
    }

    /// Stores a key/value pair only if the key isn't there yet.
    ///
    /// The same as ``put(_:forKey:in:options:)-(RawSpan,RawSpan,_,_)`` with
    /// ``PutOptions/noOverwrite``, reporting an existing key as `false`
    /// rather than an error.
    ///
    /// - Returns: Whether the pair was stored.
    @discardableResult
    public mutating func insert(_ value: RawSpan, forKey key: RawSpan, in database: Database) throws(LMDBError) -> Bool {
        do {
            try put(value, forKey: key, in: database, options: .noOverwrite)
            return true
        } catch .keyExists {
            return false
        }
    }

    /// Reserves space for a value and lets `initializer` write it in place
    /// (`MDB_RESERVE`).
    ///
    /// Saves copying a value that is generated anyway: LMDB reserves
    /// `byteCount` bytes in the database, and `initializer` writes them
    /// directly.
    ///
    /// ```swift
    /// try txn.put(reservingByteCount: 12, forKey: id, in: db) { out in
    ///     out.append(header, as: UInt32.self, .bigEndian)
    ///     out.append(timestamp, as: UInt64.self, .bigEndian)
    /// }
    /// ```
    ///
    /// LMDB doesn't initialize the reserved space, which may hold stale bytes
    /// from freed pages. So `initializer` gets an `OutputRawSpan`, which can
    /// only append, and nothing unwritten can be read through it. It must
    /// write exactly `byteCount` bytes, or the program traps, and it can't
    /// throw, because by the time it runs the entry exists.
    ///
    /// - Parameters:
    ///   - byteCount: The size of the value.
    ///   - key: The key.
    ///   - database: The database to store in. Not a
    ///     ``DatabaseOptions/duplicateSort`` database, where LMDB doesn't
    ///     support this (and doesn't check).
    ///   - options: How to store it.
    ///   - initializer: Writes the value.
    /// - Throws: ``LMDBError/incompatible`` for a
    ///   ``DatabaseOptions/duplicateSort`` database, or the errors of
    ///   ``put(_:forKey:in:options:)-(RawSpan,RawSpan,_,_)``.
    public mutating func put(
        reservingByteCount byteCount: Int,
        forKey key: RawSpan,
        in database: Database,
        options: PutOptions = [],
        initializingWith initializer: (inout OutputRawSpan) -> Void
    ) throws(LMDBError) {
        guard !database.options.contains(.duplicateSort) else { throw .incompatible }
        precondition(byteCount >= 0, "byteCount must be non-negative")
        let reserved = try key.withMDBVal { (keyVal) throws(LMDBError) -> MDB_val in
            var k = CollectionOfOne(keyVal)
            var d = CollectionOfOne(unsafe MDB_val(mv_size: byteCount, mv_data: nil))
            var kSpan = k.mutableSpan
            var dSpan = d.mutableSpan
            let flags = options.rawValue | UInt32(MDB_RESERVE)
            try check(raw.put(database.handle, key: &kSpan, data: &dSpan, flags: flags))
            return d[0]
        }
        let buffer = unsafe UnsafeMutableRawBufferPointer(start: reserved.mv_data, count: reserved.mv_size)
        var output = unsafe OutputRawSpan(buffer: buffer, initializedCount: 0)
        initializer(&output)
        let written = unsafe output.finalize(for: buffer)
        precondition(written == byteCount, "reserved \(byteCount) bytes but wrote \(written)")
    }

    // MARK: Deleting

    /// Deletes a key and its value, or all its values in a
    /// ``DatabaseOptions/duplicateSort`` database (`mdb_del`).
    ///
    /// - Parameters:
    ///   - key: The key to delete.
    ///   - database: The database to delete from.
    /// - Returns: Whether the key was there.
    @discardableResult
    public mutating func delete(forKey key: RawSpan, in database: Database) throws(LMDBError) -> Bool {
        try key.withMDBVal { (keyVal) throws(LMDBError) -> Bool in
            var k = CollectionOfOne(keyVal)
            var kSpan = k.mutableSpan
            // NULL data: `counted_by_or_null` makes this an optional span.
            var noData: MutableSpan<MDB_val>? = nil
            return try deleted(raw.delete(database.handle, key: &kSpan, data: &noData))
        }
    }

    /// Deletes one key/value pair from a ``DatabaseOptions/duplicateSort``
    /// database, keeping the key's other values (`mdb_del`).
    ///
    /// In other databases `value` is ignored, and the key is deleted.
    ///
    /// - Parameters:
    ///   - value: The value to delete.
    ///   - key: The key it belongs to.
    ///   - database: The database to delete from.
    /// - Returns: Whether the pair was there.
    @discardableResult
    public mutating func delete(_ value: RawSpan, forKey key: RawSpan, in database: Database) throws(LMDBError) -> Bool {
        try key.withMDBVal { (keyVal) throws(LMDBError) -> Bool in
            try value.withMDBVal { (dataVal) throws(LMDBError) -> Bool in
                var k = CollectionOfOne(keyVal)
                var d = CollectionOfOne(dataVal)
                var kSpan = k.mutableSpan
                var dSpan: MutableSpan<MDB_val>? = d.mutableSpan
                return try deleted(raw.delete(database.handle, key: &kSpan, data: &dSpan))
            }
        }
    }

    /// Deletes every entry in a database, keeping the database itself
    /// (`mdb_drop` with `del` = 0).
    public mutating func removeAll(in database: Database) throws(LMDBError) {
        try check(raw.drop(database.handle, delete: 0))
    }

    /// Deletes a database and everything in it from the environment
    /// (`mdb_drop` with `del` = 1).
    ///
    /// Once this transaction commits, every copy of the handle is invalid,
    /// and using one throws ``LMDBError/badDatabase``.
    ///
    /// The main database can't be deleted, only emptied: for it, LMDB
    /// ignores the delete and this behaves like ``removeAll(in:)``, leaving
    /// the handle valid.
    public mutating func dropDatabase(_ database: Database) throws(LMDBError) {
        try check(raw.drop(database.handle, delete: 1))
    }
}

/// Special options for storing a key/value pair.
///
/// Used by ``WriteTransaction/put(_:forKey:in:options:)-(RawSpan,RawSpan,_,_)`` and
/// ``Cursor/put(_:forKey:options:)-(RawSpan,_,_)``.
public struct PutOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Store the pair only if the key isn't in the database yet
    /// (`MDB_NOOVERWRITE`).
    ///
    /// Otherwise the put throws ``LMDBError/keyExists``, even in a
    /// ``DatabaseOptions/duplicateSort`` database.
    public static let noOverwrite = PutOptions(rawValue: UInt32(MDB_NOOVERWRITE))

    /// Store the pair only if this exact key/value pair isn't in the database
    /// yet (`MDB_NODUPDATA`). Only for ``DatabaseOptions/duplicateSort``
    /// databases; otherwise the put throws ``LMDBError/keyExists``.
    public static let noDuplicateData = PutOptions(rawValue: UInt32(MDB_NODUPDATA))

    /// Append the pair at the end of the database (`MDB_APPEND`).
    ///
    /// Allows fast bulk loading when keys arrive already in order. A key out
    /// of order throws ``LMDBError/keyExists``.
    public static let append = PutOptions(rawValue: UInt32(MDB_APPEND))

    /// As ``append``, for sorted values of a key in a
    /// ``DatabaseOptions/duplicateSort`` database (`MDB_APPENDDUP`).
    public static let appendDuplicate = PutOptions(rawValue: UInt32(MDB_APPENDDUP))
}

/// `true` for success, `false` for MDB_NOTFOUND, throwing anything else.
private func deleted(_ rc: Int32) throws(LMDBError) -> Bool {
    if rc == MDB_NOTFOUND { return false }
    try check(rc)
    return true
}

// MARK: - Shared plumbing

extension MDB_txn {
    /// mdb_get, returning the result as a RawSpan whose lifetime the caller
    /// must tie to the owning transaction.
    @_lifetime(immortal)
    func value(forKey key: RawSpan, in database: Database) throws(LMDBError) -> RawSpan? {
        guard let found = try lookup(forKey: key, in: database) else { return nil }
        return unsafe found.mapSpan()
    }

    /// mdb_get, returning the raw `MDB_val`, which (unlike a span) can be
    /// returned out of a closure.
    func lookup(forKey key: RawSpan, in database: Database) throws(LMDBError) -> MDB_val? {
        try key.withMDBVal { (keyVal) throws(LMDBError) -> MDB_val? in
            var k = CollectionOfOne(keyVal)
            var d = CollectionOfOne(MDB_val())
            var kSpan = k.mutableSpan
            var dSpan = d.mutableSpan
            let rc = get(database.handle, key: &kSpan, data: &dSpan)
            if rc == MDB_NOTFOUND { return nil }
            try check(rc)
            return d[0]
        }
    }
}

extension MDB_val {
    /// The bytes this value points at, for a value LMDB filled in with a
    /// pointer into the memory map.
    ///
    /// Unsafe: the span is immortal as far as the compiler knows. Callers must
    /// tie it to the transaction (or cursor) that keeps the map page valid.
    @unsafe
    @_lifetime(immortal)
    func mapSpan() -> RawSpan {
        let bytes = unsafe UnsafeRawBufferPointer(start: mv_data, count: mv_size)
        return unsafe _overrideLifetime(RawSpan(_unsafeBytes: bytes), borrowing: ())
    }
}

extension RawSpan {
    /// Presents the span as an `MDB_val` for the duration of `body`.
    ///
    /// The one irreducibly unsafe step: MDB_val is a C struct holding a bare
    /// pointer, which bounds-safety annotations cannot describe. LMDB never
    /// writes through it for keys or (without MDB_RESERVE) for put data, so
    /// casting away const is sound.
    func withMDBVal<Result, Failure: Error>(
        _ body: (MDB_val) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try withUnsafeBytes { (bytes) throws(Failure) in
            try unsafe body(MDB_val(
                mv_size: bytes.count,
                mv_data: UnsafeMutableRawPointer(mutating: bytes.baseAddress)))
        }
    }
}
