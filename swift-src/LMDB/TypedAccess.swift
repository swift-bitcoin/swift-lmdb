import CLMDBInterop

// Overloads taking `LMDBEncodable` keys and values (`Int`, `String`, `Date`,
// `UUID`, `Data`, `[UInt8]`, ...) and returning `LMDBDecodable` ones, layered
// over the RawSpan API.
//
// Keys are encoded into a temporary allocation (or passed directly, for types
// that already hold their bytes). Values are encoded straight into the map with
// MDB_RESERVE where LMDB allows it, so a typed `put` copies no more than an
// untyped one.

// MARK: - Reading

extension ReadTransaction {
    /// Returns the raw bytes stored for a typed `key` (`mdb_get`), without
    /// copying them.
    ///
    /// See ``value(forKey:in:)-(RawSpan,_)``.
    @_lifetime(borrow self)
    public func value(forKey key: some LMDBEncodable, in database: Database) throws(LMDBError) -> RawSpan? {
        guard let found = try raw.lookup(encodedKey: key, in: database) else { return nil }
        return unsafe _overrideLifetime(found.mapSpan(), borrowing: self)
    }

    /// Returns the value stored for `key`, decoded as `Value`, or `nil` if the
    /// key isn't in the database (`mdb_get`).
    ///
    /// ```swift
    /// let name: String? = try txn.value(forKey: userID, in: names)
    /// let age = try txn.value(forKey: userID, in: ages, as: Int.self)
    /// ```
    ///
    /// - Parameters:
    ///   - key: The key to look up.
    ///   - database: The database to look in.
    ///   - type: The type to decode the stored bytes as.
    /// - Returns: The decoded value, or `nil` if `key` isn't there.
    /// - Throws: ``LMDBError`` if the lookup fails, or ``LMDBDecodingError``
    ///   if the stored bytes are not a valid `Value`.
    public func value<Value: LMDBDecodable>(
        forKey key: some LMDBEncodable,
        in database: Database,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        try raw.decodedValue(forKey: key, in: database)
    }
}

extension WriteTransaction {
    /// Returns the raw bytes stored for a typed `key` (`mdb_get`), without
    /// copying them, including this transaction's own uncommitted changes.
    ///
    /// See ``value(forKey:in:)-(RawSpan,_)``.
    @_lifetime(borrow self)
    public func value(forKey key: some LMDBEncodable, in database: Database) throws(LMDBError) -> RawSpan? {
        guard let found = try raw.lookup(encodedKey: key, in: database) else { return nil }
        return unsafe _overrideLifetime(found.mapSpan(), borrowing: self)
    }

    /// Returns the value stored for `key`, decoded as `Value`, or `nil` if the
    /// key isn't in the database (`mdb_get`).
    ///
    /// See ``ReadTransaction/value(forKey:in:as:)``.
    public func value<Value: LMDBDecodable>(
        forKey key: some LMDBEncodable,
        in database: Database,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        try raw.decodedValue(forKey: key, in: database)
    }
}

extension MDB_txn {
    fileprivate func lookup(encodedKey key: some LMDBEncodable, in database: Database) throws(LMDBError) -> MDB_val? {
        try key.withEncodedBytes { (key) throws(LMDBError) in try lookup(forKey: key, in: database) }
    }

    fileprivate func decodedValue<Value: LMDBDecodable>(
        forKey key: some LMDBEncodable,
        in database: Database
    ) throws -> Value? {
        guard let found = try lookup(encodedKey: key, in: database) else { return nil }
        // Sound: the span is used only for this call, while the transaction
        // the caller borrows keeps the page alive.
        return try Value(lmdbBytes: unsafe found.mapSpan())
    }
}

// MARK: - Writing

extension WriteTransaction {
    /// Encodes and stores `value` for `key` (`mdb_put`).
    ///
    /// Outside ``DatabaseOptions/duplicateSort`` databases the value is
    /// encoded directly into the database (`MDB_RESERVE`), with no
    /// intermediate buffer. See ``put(_:forKey:in:options:)-(RawSpan,RawSpan,_,_)``.
    public mutating func put(
        _ value: some LMDBEncodable,
        forKey key: some LMDBEncodable,
        in database: Database,
        options: PutOptions = []
    ) throws(LMDBError) {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try put(value, forKey: key, in: database, options: options)
        }
    }

    /// Encodes and stores `value` for an already-encoded `key` (`mdb_put`).
    ///
    /// Outside ``DatabaseOptions/duplicateSort`` databases the value is
    /// encoded directly into the database (`MDB_RESERVE`).
    public mutating func put(
        _ value: some LMDBEncodable,
        forKey key: RawSpan,
        in database: Database,
        options: PutOptions = []
    ) throws(LMDBError) {
        if database.options.contains(.duplicateSort) {
            // MDB_RESERVE is not allowed here; encode to a buffer instead.
            try value.withEncodedBytes { (value) throws(LMDBError) in
                try put(value, forKey: key, in: database, options: options)
            }
        } else {
            try put(reservingByteCount: value.encodedByteCount, forKey: key, in: database, options: options) {
                value.encode(into: &$0)
            }
        }
    }

    /// Stores already-encoded bytes for a typed `key` (`mdb_put`).
    public mutating func put(
        _ value: RawSpan,
        forKey key: some LMDBEncodable,
        in database: Database,
        options: PutOptions = []
    ) throws(LMDBError) {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try put(value, forKey: key, in: database, options: options)
        }
    }

    /// Encodes and stores `value` for `key` only if the key isn't in the
    /// database yet (`mdb_put` with `MDB_NOOVERWRITE`).
    ///
    /// - Returns: Whether the pair was stored.
    @discardableResult
    public mutating func insert(
        _ value: some LMDBEncodable,
        forKey key: some LMDBEncodable,
        in database: Database
    ) throws(LMDBError) -> Bool {
        do {
            try put(value, forKey: key, in: database, options: .noOverwrite)
            return true
        } catch .keyExists {
            return false
        }
    }

    /// Reserves space for a value under a typed `key` and lets `initializer`
    /// write it in place (`MDB_RESERVE`).
    ///
    /// See ``put(reservingByteCount:forKey:in:options:initializingWith:)-(Int,RawSpan,_,_,_)``.
    public mutating func put(
        reservingByteCount byteCount: Int,
        forKey key: some LMDBEncodable,
        in database: Database,
        options: PutOptions = [],
        initializingWith initializer: (inout OutputRawSpan) -> Void
    ) throws(LMDBError) {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try put(reservingByteCount: byteCount, forKey: key, in: database, options: options,
                    initializingWith: initializer)
        }
    }

    /// Deletes a typed `key` and all of its values (`mdb_del`).
    ///
    /// - Returns: Whether the key was in the database.
    @discardableResult
    public mutating func delete(forKey key: some LMDBEncodable, in database: Database) throws(LMDBError) -> Bool {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try delete(forKey: key, in: database)
        }
    }

    /// Deletes one specific `key`/`value` pair in a
    /// ``DatabaseOptions/duplicateSort`` database (`mdb_del`).
    ///
    /// - Returns: Whether that pair was in the database.
    @discardableResult
    public mutating func delete(
        _ value: some LMDBEncodable,
        forKey key: some LMDBEncodable,
        in database: Database
    ) throws(LMDBError) -> Bool {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try value.withEncodedBytes { (value) throws(LMDBError) in
                try delete(value, forKey: key, in: database)
            }
        }
    }
}

// MARK: - Cursors

extension Cursor {
    /// Positions at the specified typed `key` (`MDB_SET`).
    ///
    /// See ``seek(to:)-(RawSpan)``.
    @_lifetime(borrow self)
    public func seek(to key: some LMDBEncodable) throws(LMDBError) -> CursorEntry? {
        try position(.set, key: key) ? entry(.getCurrent) : nil
    }

    /// Positions at the first key greater than or equal to a typed `key`
    /// (`MDB_SET_RANGE`).
    ///
    /// See ``seek(atOrAfter:)-(RawSpan)``.
    @_lifetime(borrow self)
    public func seek(atOrAfter key: some LMDBEncodable) throws(LMDBError) -> CursorEntry? {
        try position(.setRange, key: key) ? entry(.getCurrent) : nil
    }

    /// Positions at the exact typed `key` and `value` pair (`MDB_GET_BOTH`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases. See
    /// ``seek(to:value:)-(RawSpan,RawSpan)``.
    @_lifetime(borrow self)
    public func seek(to key: some LMDBEncodable, value: some LMDBEncodable) throws(LMDBError) -> CursorEntry? {
        try position(.getBoth, key: key, value: value) ? entry(.getCurrent) : nil
    }

    /// Positions at a typed `key` and the first of its values greater than or
    /// equal to `value` (`MDB_GET_BOTH_RANGE`).
    ///
    /// Only for ``DatabaseOptions/duplicateSort`` databases. See
    /// ``seek(to:valueAtOrAfter:)-(RawSpan,RawSpan)``.
    @_lifetime(borrow self)
    public func seek(to key: some LMDBEncodable, valueAtOrAfter value: some LMDBEncodable) throws(LMDBError) -> CursorEntry? {
        try position(.getBothRange, key: key, value: value) ? entry(.getCurrent) : nil
    }

    /// Positions the cursor; the entry is then read with `getCurrent`, since
    /// a span cannot be returned out of the encoding closure.
    private func position(_ op: MDB_cursor_op, key: some LMDBEncodable) throws(LMDBError) -> Bool {
        try key.withEncodedBytes { (key) throws(LMDBError) in try get(op, key: key) != nil }
    }

    private func position(
        _ op: MDB_cursor_op,
        key: some LMDBEncodable,
        value: some LMDBEncodable
    ) throws(LMDBError) -> Bool {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try value.withEncodedBytes { (value) throws(LMDBError) in
                try get(op, key: key, value: value) != nil
            }
        }
    }
}

extension Cursor where Access == ReadWrite {
    /// Encodes and stores `value` for `key` by cursor (`mdb_cursor_put`).
    ///
    /// See ``put(_:forKey:options:)-(RawSpan,RawSpan,_)``.
    public mutating func put(
        _ value: some LMDBEncodable,
        forKey key: some LMDBEncodable,
        options: PutOptions = []
    ) throws(LMDBError) {
        try key.withEncodedBytes { (key) throws(LMDBError) in
            try value.withEncodedBytes { (value) throws(LMDBError) in
                try put(value, forKey: key, options: options)
            }
        }
    }
}

extension CursorEntry {
    /// Decodes the entry's key as `Key`.
    ///
    /// - Parameter type: The type to decode the key as.
    /// - Throws: ``LMDBDecodingError`` if the key bytes are not a valid `Key`.
    public func key<Key: LMDBDecodable>(as type: Key.Type = Key.self) throws(LMDBDecodingError) -> Key {
        try Key(lmdbBytes: key)
    }

    /// Decodes the entry's value as `Value`.
    ///
    /// - Parameter type: The type to decode the value as.
    /// - Throws: ``LMDBDecodingError`` if the value bytes are not a valid
    ///   `Value`.
    public func value<Value: LMDBDecodable>(as type: Value.Type = Value.self) throws(LMDBDecodingError) -> Value {
        try Value(lmdbBytes: value)
    }
}

extension DuplicateBatch {
    /// Decodes the batch's key as `Key`.
    ///
    /// - Parameter type: The type to decode the key as.
    /// - Throws: ``LMDBDecodingError`` if the key bytes are not a valid `Key`.
    public func key<Key: LMDBDecodable>(as type: Key.Type = Key.self) throws(LMDBDecodingError) -> Key {
        try Key(lmdbBytes: key)
    }

    /// Decodes all values in the batch, each `valueSize` bytes long, as
    /// `Value`.
    ///
    /// - Parameters:
    ///   - type: The type to decode each value as.
    ///   - valueSize: The fixed size in bytes of each value in the database.
    /// - Returns: The decoded values in sorted order.
    /// - Throws: ``LMDBDecodingError`` if ``values`` is not a multiple of
    ///   `valueSize` bytes or any element fails to decode.
    public func values<Value: LMDBDecodable>(
        as type: Value.Type = Value.self,
        valueSize: Int
    ) throws(LMDBDecodingError) -> [Value] {
        precondition(valueSize > 0, "valueSize must be positive")
        guard values.byteCount.isMultiple(of: valueSize) else {
            throw LMDBDecodingError([Value].self, byteCount: values.byteCount,
                                    reason: "not a multiple of \(valueSize) bytes")
        }
        var decoded: [Value] = []
        decoded.reserveCapacity(values.byteCount / valueSize)
        for offset in stride(from: 0, to: values.byteCount, by: valueSize) {
            decoded.append(try Value(lmdbBytes: values.extracting(offset..<offset + valueSize)))
        }
        return decoded
    }
}
