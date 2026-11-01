import CLMDBInterop

/// Marks a ``Cursor`` that can only read.
public enum ReadOnly {}

/// Marks a ``Cursor`` that can also write and delete, opened from a
/// ``WriteTransaction`` passed `inout`.
public enum ReadWrite {}

/// A position in a database, for ordered iteration, range and prefix scans,
/// and walking the values of duplicate keys (`MDB_cursor`).
///
/// Like transactions, a cursor is non-copyable and non-escapable: its lifetime
/// depends on the ``ReadTransaction`` or ``WriteTransaction`` it was opened
/// from, so it can't be used after that transaction ends.
///
/// ```swift
/// try env.read { txn in
///     let cursor = try Cursor(txn, database: db)
///     while let entry = try cursor.next() {
///         // entry.key and entry.value are RawSpans into the map
///     }
/// }
/// ```
///
/// Movement (``next()``, ``seek(to:)-(RawSpan)``, ...) doesn't invalidate
/// entries returned earlier, so it borrows the cursor and several
/// ``CursorEntry`` values may be held at once. Modifications
/// (``put(_:forKey:options:)-(RawSpan,RawSpan,_)``, ``delete()``) do
/// invalidate them, so they are `mutating` and the compiler rejects them while
/// an entry is still in use.
///
/// Every positioning operation returns `nil` when there is nothing at the
/// requested position (`MDB_NOTFOUND`), and throws ``LMDBError`` for anything
/// else. Operations for ``DatabaseOptions/duplicateSort`` or
/// ``DatabaseOptions/duplicateFixed`` databases throw
/// ``LMDBError/incompatible`` on other databases.
///
/// See <doc:Cursors> for range scans, duplicate navigation and in-place
/// deletion patterns.
public struct Cursor<Access>: ~Copyable, ~Escapable {
    let raw: MDB_cursor

    /// Whether `deinit` closes the cursor, which is only right in a read
    /// transaction.
    ///
    /// LMDB frees a write transaction's cursors itself on commit or abort, so
    /// closing one afterwards is a use-after-free. The lifetime dependency
    /// stops the cursor being *used* after `commit()`, but not its `deinit`
    /// from running there: given `var c = try Cursor(&txn, ...)`, then
    /// `try txn.commit()` with `c` still in scope, the compiler accepts it and
    /// destroys `c` at the end of the scope. AddressSanitizer catches exactly
    /// that (see `cursorStillInScopeAtCommit`).
    ///
    /// A read transaction's cursors are not tracked, and LMDB documents that
    /// they may be closed before *or after* the transaction ends, so a late
    /// `deinit` is harmless there.
    let closesOnDeinit: Bool

    @_lifetime(immortal)
    fileprivate init(opening database: Database, in transaction: MDB_txn, closesOnDeinit: Bool) throws(LMDBError) {
        var out = CollectionOfOne<MDB_cursor?>(nil)
        var outSpan = out.mutableSpan
        try check(transaction.openCursor(database.handle, &outSpan))
        raw = out[0]!
        self.closesOnDeinit = closesOnDeinit
    }

    deinit {
        if closesOnDeinit { raw.close() }
    }
}

extension Cursor where Access == ReadOnly {
    /// Opens a read-only cursor in a read transaction (`mdb_cursor_open`).
    ///
    /// - Parameters:
    ///   - transaction: The read transaction to borrow.
    ///   - database: The database to traverse.
    /// - Throws: ``LMDBError`` if the cursor can't be allocated (`ENOMEM`) or
    ///   `database` is invalid.
    @_lifetime(borrow transaction)
    public init(_ transaction: borrowing ReadTransaction, database: Database) throws(LMDBError) {
        let cursor = try Cursor(opening: database, in: transaction.raw, closesOnDeinit: true)
        self = unsafe _overrideLifetime(cursor, borrowing: transaction)
    }

    /// Opens a read-only cursor in a write transaction (`mdb_cursor_open`).
    ///
    /// The transaction is borrowed, so it cannot be written to while the
    /// cursor is open.
    ///
    /// - Parameters:
    ///   - transaction: The write transaction to borrow.
    ///   - database: The database to traverse.
    /// - Throws: ``LMDBError`` if the cursor can't be allocated or `database`
    ///   is invalid.
    @_lifetime(borrow transaction)
    public init(_ transaction: borrowing WriteTransaction, database: Database) throws(LMDBError) {
        let cursor = try Cursor(opening: database, in: transaction.raw, closesOnDeinit: false)
        self = unsafe _overrideLifetime(cursor, borrowing: transaction)
    }
}

extension Cursor where Access == ReadWrite {
    /// Opens a cursor that can also write and delete (`mdb_cursor_open`).
    ///
    /// The transaction is accessed exclusively while the cursor is open, so no
    /// other read or write on the transaction can observe or invalidate what
    /// the cursor does.
    ///
    /// - Parameters:
    ///   - transaction: The write transaction, accessed `inout` while the
    ///     cursor is alive.
    ///   - database: The database to traverse and modify.
    /// - Throws: ``LMDBError`` if the cursor can't be allocated or `database`
    ///   is invalid.
    @_lifetime(&transaction)
    public init(_ transaction: inout WriteTransaction, database: Database) throws(LMDBError) {
        let cursor = try Cursor(opening: database, in: transaction.raw, closesOnDeinit: false)
        self = unsafe _overrideLifetime(cursor, mutating: &transaction)
    }
}

/// A key and value at a ``Cursor`` position, both pointing into the memory
/// map.
///
/// Non-escapable: it depends on a borrow of the cursor that produced it, so it
/// cannot outlive the cursor or survive a cursor write or delete.
public struct CursorEntry: ~Escapable {
    /// The entry's key, pointing into the memory map.
    public let key: RawSpan
    /// The entry's value, pointing into the memory map.
    public let value: RawSpan

    @_lifetime(copy key, copy value)
    init(key: RawSpan, value: RawSpan) {
        self.key = key
        self.value = value
    }

    /// A copy of the key, for when it must outlive the cursor or a later
    /// cursor modification.
    public var keyBytes: [UInt8] { [UInt8](key) }

    /// A copy of the value, for when it must outlive the cursor or a later
    /// cursor modification.
    public var valueBytes: [UInt8] { [UInt8](value) }
}

/// Up to one page of values of a single key in a
/// ``DatabaseOptions/duplicateFixed`` database, packed back to back with no
/// separators (`MDB_GET_MULTIPLE`).
///
/// Every value has the same size, so `values.byteCount / valueSize` is the
/// number of values in the batch. Use ``values(as:valueSize:)`` to decode all
/// of them at once.
public struct DuplicateBatch: ~Escapable {
    /// The key these values belong to, pointing into the memory map.
    public let key: RawSpan
    /// The packed values, contiguous in the memory map.
    public let values: RawSpan

    @_lifetime(copy key, copy values)
    init(key: RawSpan, values: RawSpan) {
        self.key = key
        self.values = values
    }

    /// A copy of the key, for when it must outlive the cursor.
    public var keyBytes: [UInt8] { [UInt8](key) }

    /// A copy of the packed values, for when they must outlive the cursor.
    public var valuesBytes: [UInt8] { [UInt8](values) }
}

// MARK: - Positioning

extension Cursor {
    /// Positions at the first key/value item in the database (`MDB_FIRST`).
    ///
    /// - Returns: The first entry, or `nil` if the database is empty.
    @_lifetime(borrow self)
    public func first() throws(LMDBError) -> CursorEntry? { try entry(.first) }

    /// Positions at the last key/value item in the database (`MDB_LAST`).
    ///
    /// In a ``DatabaseOptions/duplicateSort`` database this is the last value
    /// of the last key.
    ///
    /// - Returns: The last entry, or `nil` if the database is empty.
    @_lifetime(borrow self)
    public func last() throws(LMDBError) -> CursorEntry? { try entry(.last) }

    /// Positions at the next item, or the first one if the cursor isn't
    /// positioned yet (`MDB_NEXT`).
    ///
    /// `while let entry = try cursor.next()` visits every entry in the
    /// database in order. In a ``DatabaseOptions/duplicateSort`` database it
    /// visits every value of every key; use ``nextKey()`` to step by distinct
    /// keys instead, or ``nextDuplicate()`` to stay within the current key.
    ///
    /// - Returns: The next entry, or `nil` after the last one.
    @_lifetime(borrow self)
    public func next() throws(LMDBError) -> CursorEntry? { try entry(.next) }

    /// Positions at the previous item, or the last one if the cursor isn't
    /// positioned yet (`MDB_PREV`).
    ///
    /// In a ``DatabaseOptions/duplicateSort`` database this steps through
    /// every value of every key in reverse; use ``previousKey()`` to step by
    /// distinct keys, or ``previousDuplicate()`` to stay within the current
    /// key.
    ///
    /// - Returns: The previous entry, or `nil` before the first one.
    @_lifetime(borrow self)
    public func previous() throws(LMDBError) -> CursorEntry? { try entry(.previous) }

    /// Returns the key and value at the current cursor position without moving
    /// (`MDB_GET_CURRENT`).
    ///
    /// - Returns: The current entry, or `nil` if the cursor has moved past the
    ///   end.
    /// - Throws: ``LMDBError`` (`EINVAL`) if the cursor hasn't been positioned
    ///   yet.
    @_lifetime(borrow self)
    public func current() throws(LMDBError) -> CursorEntry? { try entry(.getCurrent) }

    /// Positions at the specified `key` (`MDB_SET`).
    ///
    /// In a ``DatabaseOptions/duplicateSort`` database this positions at the
    /// key's first value.
    ///
    /// - Parameter key: The exact key to find.
    /// - Returns: The entry for `key`, or `nil` if `key` isn't in the
    ///   database.
    @_lifetime(borrow self)
    public func seek(to key: RawSpan) throws(LMDBError) -> CursorEntry? {
        try entry(.set, key: key)
    }

    /// Positions at the first key greater than or equal to `key`
    /// (`MDB_SET_RANGE`).
    ///
    /// Use this to start a range or prefix scan, then step forward with
    /// ``next()`` while the returned keys remain in range.
    ///
    /// - Parameter key: The lower bound of the scan.
    /// - Returns: The first entry at or after `key`, or `nil` if every key in
    ///   the database precedes `key`.
    @_lifetime(borrow self)
    public func seek(atOrAfter key: RawSpan) throws(LMDBError) -> CursorEntry? {
        try entry(.setRange, key: key)
    }
}

// MARK: - Duplicate keys

extension Cursor {
    /// Positions at the first item of the next key, skipping any remaining
    /// duplicate values of the current key (`MDB_NEXT_NODUP`).
    ///
    /// Behaves like ``next()`` outside ``DatabaseOptions/duplicateSort``
    /// databases.
    ///
    /// - Returns: The first entry of the next key, or `nil` after the last
    ///   key.
    @_lifetime(borrow self)
    public func nextKey() throws(LMDBError) -> CursorEntry? { try entry(.nextKey) }

    /// Positions at the last item of the previous key, skipping any remaining
    /// duplicate values of the current key (`MDB_PREV_NODUP`).
    ///
    /// Behaves like ``previous()`` outside ``DatabaseOptions/duplicateSort``
    /// databases.
    ///
    /// - Returns: The last entry of the previous key, or `nil` before the
    ///   first key.
    @_lifetime(borrow self)
    public func previousKey() throws(LMDBError) -> CursorEntry? { try entry(.previousKey) }

    /// Positions at the first value of the current key (`MDB_FIRST_DUP`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases; the cursor must
    /// already be positioned on a key.
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    @_lifetime(borrow self)
    public func firstDuplicate() throws(LMDBError) -> CursorEntry? { try entry(.firstDuplicate) }

    /// Positions at the last value of the current key (`MDB_LAST_DUP`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases; the cursor must
    /// already be positioned on a key.
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    @_lifetime(borrow self)
    public func lastDuplicate() throws(LMDBError) -> CursorEntry? { try entry(.lastDuplicate) }

    /// Positions at the next value of the current key, staying on the same
    /// key (`MDB_NEXT_DUP`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases.
    ///
    /// - Returns: The next value of the current key, or `nil` if the cursor is
    ///   already at the key's last value.
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    @_lifetime(borrow self)
    public func nextDuplicate() throws(LMDBError) -> CursorEntry? { try entry(.nextDuplicate) }

    /// Positions at the previous value of the current key, staying on the same
    /// key (`MDB_PREV_DUP`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases.
    ///
    /// - Returns: The previous value of the current key, or `nil` if the
    ///   cursor is already at the key's first value.
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    @_lifetime(borrow self)
    public func previousDuplicate() throws(LMDBError) -> CursorEntry? { try entry(.previousDuplicate) }

    /// Positions at the exact `key` and `value` pair (`MDB_GET_BOTH`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases.
    ///
    /// - Parameters:
    ///   - key: The exact key to find.
    ///   - value: The exact value of `key` to find.
    /// - Returns: The matching entry, or `nil` if that pair isn't in the
    ///   database.
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    @_lifetime(borrow self)
    public func seek(to key: RawSpan, value: RawSpan) throws(LMDBError) -> CursorEntry? {
        try entry(.getBoth, key: key, value: value)
    }

    /// Positions at `key` and the first of its values greater than or equal to
    /// `value` (`MDB_GET_BOTH_RANGE`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases.
    ///
    /// - Parameters:
    ///   - key: The exact key to find.
    ///   - value: The lower bound on `key`'s values.
    /// - Returns: The first matching entry for `key`, or `nil` if `key` isn't
    ///   in the database or all of its values precede `value`.
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    @_lifetime(borrow self)
    public func seek(to key: RawSpan, valueAtOrAfter value: RawSpan) throws(LMDBError) -> CursorEntry? {
        try entry(.getBothRange, key: key, value: value)
    }

    /// Returns the number of duplicate values for the current key
    /// (`mdb_cursor_count`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases; the cursor must
    /// already be positioned on a key.
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``, or ``LMDBError`` (`EINVAL`) if the
    ///   cursor isn't positioned.
    public func duplicateCount() throws(LMDBError) -> Int {
        var count = CollectionOfOne<mdb_size_t>(0)
        var countSpan = count.mutableSpan
        try check(raw.duplicateCount(&countSpan))
        return Int(count[0])
    }
}

// MARK: - Batches of fixed-size duplicates

extension Cursor {
    /// Returns up to a page of duplicate values for the current key, starting
    /// from the page that holds the current position (`MDB_GET_MULTIPLE`).
    ///
    /// Only for ``DatabaseOptions/duplicateFixed`` databases; the cursor must
    /// already be positioned on a key. Batches never cross keys. To read every
    /// value of a key:
    ///
    /// ```swift
    /// _ = try cursor.seek(to: key)              // or first(), nextKey(), ...
    /// if let batch = try cursor.duplicateBatch() { ... }
    /// while let batch = try cursor.nextDuplicateBatch() { ... }
    /// ```
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateFixed``, or ``LMDBError`` (`EINVAL`) if
    ///   the cursor isn't positioned.
    @_lifetime(borrow self)
    public func duplicateBatch() throws(LMDBError) -> DuplicateBatch? { try batch(.getMultiple) }

    /// Positions at and returns the next page of duplicate values for the
    /// current key, or `nil` after its last page (`MDB_NEXT_MULTIPLE`).
    ///
    /// Does not move on to the next key: use ``nextKey()`` for that. Only for
    /// ``DatabaseOptions/duplicateFixed`` databases.
    ///
    /// Call ``duplicateBatch()`` first after positioning the cursor: this
    /// advances past the current page before reading, so calling it first
    /// skips the first page of values.
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateFixed``.
    @_lifetime(borrow self)
    public func nextDuplicateBatch() throws(LMDBError) -> DuplicateBatch? { try batch(.nextMultiple) }

    /// Positions at and returns the previous page of duplicate values for the
    /// current key, or `nil` before its first page (`MDB_PREV_MULTIPLE`).
    ///
    /// Only for ``DatabaseOptions/duplicateFixed`` databases.
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateFixed``.
    @_lifetime(borrow self)
    public func previousDuplicateBatch() throws(LMDBError) -> DuplicateBatch? { try batch(.previousMultiple) }
}

// MARK: - Writing

extension Cursor where Access == ReadWrite {
    /// Stores a key/value pair by cursor and positions the cursor on it
    /// (`mdb_cursor_put`).
    ///
    /// By default, replaces an existing value for `key`, or in a
    /// ``DatabaseOptions/duplicateSort`` database inserts `value` in sorted
    /// order among `key`'s values. See ``PutOptions`` for alternatives.
    ///
    /// - Parameters:
    ///   - value: The bytes to store.
    ///   - key: The key, between 1 and ``Environment/maxKeySize`` bytes.
    ///   - options: How to store it.
    /// - Throws: ``LMDBError/keyExists`` when `options` forbid replacing or
    ///   duplicating, ``LMDBError/mapFull``, ``LMDBError/badValueSize``, or
    ///   another ``LMDBError``.
    public mutating func put(_ value: RawSpan, forKey key: RawSpan, options: PutOptions = []) throws(LMDBError) {
        try key.withMDBVal { (keyVal) throws(LMDBError) in
            try value.withMDBVal { (dataVal) throws(LMDBError) in
                var k = CollectionOfOne(keyVal)
                var d = CollectionOfOne(dataVal)
                var kSpan = k.mutableSpan
                var dSpan = d.mutableSpan
                try check(raw.put(key: &kSpan, data: &dSpan, flags: options.rawValue))
            }
        }
    }

    /// Deletes the key/value item at the current cursor position
    /// (`mdb_cursor_del`).
    ///
    /// A following ``next()`` returns the entry after the deleted one rather
    /// than skipping it. To filter in place, use ``removeAll(where:)``, or
    /// copy what the decision needs out of the entry before deleting:
    ///
    /// ```swift
    /// while let key = try cursor.next()?.keyBytes {
    ///     if shouldDelete(key) { try cursor.delete() }
    /// }
    /// ```
    ///
    /// `while let entry = try cursor.next() { ... try cursor.delete() }` does
    /// not compile: a `while let` binding stays alive for the whole loop body,
    /// so `entry` still borrows the cursor when `delete()` needs exclusive
    /// access.
    public mutating func delete() throws(LMDBError) {
        try check(raw.delete(flags: 0))
    }

    /// Deletes every entry from the next position onwards (from the start, on
    /// a fresh cursor) for which `shouldRemove` returns `true`, and returns
    /// how many were deleted.
    ///
    /// - Parameter shouldRemove: Receives each entry in turn; returning `true`
    ///   deletes it.
    /// - Returns: The number of entries deleted.
    @discardableResult
    public mutating func removeAll(where shouldRemove: (CursorEntry) -> Bool) throws(LMDBError) -> Int {
        var removed = 0
        while let remove = try visitNext(shouldRemove) {
            if remove {
                try delete()
                removed += 1
            }
        }
        return removed
    }

    /// Moves to the next entry and returns what `body` decides about it. The
    /// entry's borrow of the cursor ends on return, so the caller can then
    /// modify the cursor.
    private func visitNext(_ body: (CursorEntry) -> Bool) throws(LMDBError) -> Bool? {
        guard let entry = try next() else { return nil }
        return body(entry)
    }

    /// Deletes all duplicate values of the current key (`mdb_cursor_del` with
    /// `MDB_NODUPDATA`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases.
    ///
    /// - Throws: ``LMDBError/incompatible`` if the database wasn't opened with
    ///   ``DatabaseOptions/duplicateSort``.
    public mutating func deleteAllDuplicates() throws(LMDBError) {
        try check(raw.delete(flags: UInt32(MDB_NODUPDATA)))
    }
}

// MARK: - Plumbing

extension Cursor {
    /// Runs `op`, then re-reads the position with `getCurrent`.
    ///
    /// The re-read matters for safety, not convenience: for `set` and
    /// `getBoth` LMDB leaves the key (and value) pointing at the caller's
    /// input buffer, and the duplicate ops do not always fill in the key. After
    /// `getCurrent` both always point into the map, which is what makes it
    /// correct to tie them to the cursor's lifetime.
    @_lifetime(borrow self)
    func entry(
        _ op: MDB_cursor_op,
        key: RawSpan? = nil,
        value: RawSpan? = nil
    ) throws(LMDBError) -> CursorEntry? {
        guard try get(op, key: key, value: value) != nil,
              let (k, v) = try get(.getCurrent)
        else { return nil }
        let entry = unsafe CursorEntry(key: k.mapSpan(), value: v.mapSpan())
        return unsafe _overrideLifetime(entry, borrowing: self)
    }

    /// Runs a `*_MULTIPLE` op: the page of values comes from the op itself,
    /// the key from a `getCurrent` afterwards.
    ///
    /// A key with a single value is stored inline rather than as a duplicate
    /// sub-tree, and for it GET_MULTIPLE reports success *without filling in
    /// the data*. Passed through, that would be an empty batch silently
    /// dropping the value, so the value from `getCurrent` stands in for it.
    @_lifetime(borrow self)
    private func batch(_ op: MDB_cursor_op) throws(LMDBError) -> DuplicateBatch? {
        guard let (_, page) = try get(op),
              let (k, current) = try get(.getCurrent)
        else { return nil }
        let values = unsafe page.mv_data == nil ? current : page
        let batch = unsafe DuplicateBatch(key: k.mapSpan(), values: values.mapSpan())
        return unsafe _overrideLifetime(batch, borrowing: self)
    }

    /// mdb_cursor_get, returning the raw outputs or `nil` for MDB_NOTFOUND.
    func get(
        _ op: MDB_cursor_op,
        key: RawSpan? = nil,
        value: RawSpan? = nil
    ) throws(LMDBError) -> (MDB_val, MDB_val)? {
        try withMDBVal(key) { (keyVal) throws(LMDBError) in
            try withMDBVal(value) { (dataVal) throws(LMDBError) in
                // `MDB_val *` is annotated `counted_by: 1`: inputs for some
                // ops, outputs for all.
                var k = CollectionOfOne(keyVal)
                var d = CollectionOfOne(dataVal)
                var kSpan = k.mutableSpan
                var dSpan = d.mutableSpan
                let rc = raw.get(key: &kSpan, data: &dSpan, op: op)
                if rc == MDB_NOTFOUND { return nil }
                try check(rc)
                return (k[0], d[0])
            }
        }
    }
}

/// `RawSpan.withMDBVal`, passing an empty `MDB_val` for `nil`.
private func withMDBVal<Result, Failure: Error>(
    _ span: RawSpan?,
    _ body: (MDB_val) throws(Failure) -> Result
) throws(Failure) -> Result {
    switch span {
    case .some(let span): try span.withMDBVal(body)
    case .none: try body(MDB_val())
    }
}
