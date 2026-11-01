#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A type that can be encoded as an LMDB key or value.
///
/// LMDB orders keys by comparing their bytes lexicographically, so the
/// built-in conformances use encodings whose byte order matches the values'
/// natural order:
///
/// | Type | Encoding | Sorts |
/// |---|---|---|
/// | Integers | Fixed-width big-endian, sign bit flipped for signed types | Numerically, negatives first |
/// | `Double`, `Float`, `Date` | IEEE 754 bits, transformed so they compare as unsigned big-endian | Numerically (`Date` chronologically) |
/// | `Bool` | One byte, `0` or `1` | `false` first |
/// | `String` | UTF-8, no terminator | By Unicode scalar value |
/// | `[UInt8]`, `Data` | The bytes themselves | Bytewise |
/// | `UUID` | Its 16 bytes | As its `uuidString` |
///
/// `Int` and `UInt` are 8 bytes on 64-bit platforms and 4 on 32-bit ones; use
/// the explicitly sized integer types (`Int64`, `UInt64`, ...) for database
/// files shared between architectures.
///
/// To store your own types, implement ``encodedByteCount`` and
/// ``encode(into:)``: `encode(into:)` must append exactly `encodedByteCount`
/// bytes. See <doc:TypedKeysAndValues> for examples.
public protocol LMDBEncodable {
    /// The exact number of bytes ``encode(into:)`` appends.
    var encodedByteCount: Int { get }

    /// Appends the encoded bytes to `output`.
    ///
    /// `output` has capacity for at least ``encodedByteCount`` bytes, and the
    /// caller verifies that this method appends exactly that many bytes.
    ///
    /// - Parameter output: The span to append the encoded representation to.
    func encode(into output: inout OutputRawSpan)

    /// Calls `body` with the encoded bytes.
    ///
    /// The default implementation encodes into a temporary allocation with
    /// ``encode(into:)``. Types that already hold their bytes contiguously in
    /// memory (`String`, `[UInt8]`, `Data`) override this to pass their own
    /// storage without copying.
    ///
    /// - Parameter body: A closure that receives the encoded bytes.
    /// - Returns: What `body` returns.
    func withEncodedBytes<Result, Failure: Error>(
        _ body: (RawSpan) throws(Failure) -> Result
    ) throws(Failure) -> Result
}

extension LMDBEncodable {
    public func withEncodedBytes<Result, Failure: Error>(
        _ body: (RawSpan) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let byteCount = encodedByteCount
        return try withTemporaryAllocation(byteCount: byteCount, alignment: 1) { (output) throws(Failure) in
            encode(into: &output)
            precondition(output.byteCount == byteCount,
                         "\(Self.self).encode(into:) wrote \(output.byteCount) bytes, declared \(byteCount)")
            return try body(output.bytes)
        }
    }
}

/// A type that can be decoded from the bytes of an LMDB key or value.
///
/// See <doc:TypedKeysAndValues> for the built-in encodings and how to write
/// custom conformances.
public protocol LMDBDecodable {
    /// Decodes a value from `bytes`.
    ///
    /// - Parameter bytes: The stored bytes, pointing into the memory map for
    ///   the duration of this call.
    /// - Throws: ``LMDBDecodingError`` if `bytes` are not a valid encoding of
    ///   `Self`.
    init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError)
}

/// A type that can be both stored in and read back from LMDB
/// (``LMDBEncodable`` & ``LMDBDecodable``).
///
/// See <doc:TypedKeysAndValues>.
public typealias LMDBCodable = LMDBEncodable & LMDBDecodable

// MARK: - Integers

extension FixedWidthInteger {
    /// XOR-ing with this flips the sign bit of a signed type, mapping
    /// `min...max` onto `0...` in order, so the big-endian bytes sort
    /// numerically. A no-op for unsigned types; its own inverse.
    fileprivate static var lmdbSignBias: Self { isSigned ? min : 0 }
}

extension LMDBEncodable where Self: FixedWidthInteger & BitwiseCopyable & ConvertibleToBytes {
    public var encodedByteCount: Int { MemoryLayout<Self>.size }

    public func encode(into output: inout OutputRawSpan) {
        output.append(self ^ Self.lmdbSignBias, as: Self.self, .bigEndian)
    }
}

extension LMDBDecodable where Self: FixedWidthInteger & ConvertibleFromBytes {
    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        try expect(bytes, count: MemoryLayout<Self>.size, for: Self.self)
        self = bytes.load(fromByteOffset: 0, as: Self.self, .bigEndian) ^ Self.lmdbSignBias
    }
}

extension Int: LMDBCodable {}
extension Int8: LMDBCodable {}
extension Int16: LMDBCodable {}
extension Int32: LMDBCodable {}
extension Int64: LMDBCodable {}
extension UInt: LMDBCodable {}
extension UInt8: LMDBCodable {}
extension UInt16: LMDBCodable {}
extension UInt32: LMDBCodable {}
extension UInt64: LMDBCodable {}

// MARK: - Floating point

// IEEE 754 values compare like sign-magnitude integers. Setting the sign bit
// of non-negative values, and inverting every bit of negative ones, turns that
// into an unsigned order: -inf < ... < -0 < +0 < ... < +inf, with NaNs at the
// ends.

extension Double: LMDBCodable {
    private static let signBit: UInt64 = 1 << 63

    public var encodedByteCount: Int { 8 }

    public func encode(into output: inout OutputRawSpan) {
        let bits = bitPattern
        let ordered = bits & Self.signBit != 0 ? ~bits : bits | Self.signBit
        output.append(ordered, as: UInt64.self, .bigEndian)
    }

    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        try expect(bytes, count: 8, for: Self.self)
        let ordered = bytes.load(fromByteOffset: 0, as: UInt64.self, .bigEndian)
        self.init(bitPattern: ordered & Self.signBit != 0 ? ordered & ~Self.signBit : ~ordered)
    }
}

extension Float: LMDBCodable {
    private static let signBit: UInt32 = 1 << 31

    public var encodedByteCount: Int { 4 }

    public func encode(into output: inout OutputRawSpan) {
        let bits = bitPattern
        let ordered = bits & Self.signBit != 0 ? ~bits : bits | Self.signBit
        output.append(ordered, as: UInt32.self, .bigEndian)
    }

    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        try expect(bytes, count: 4, for: Self.self)
        let ordered = bytes.load(fromByteOffset: 0, as: UInt32.self, .bigEndian)
        self.init(bitPattern: ordered & Self.signBit != 0 ? ordered & ~Self.signBit : ~ordered)
    }
}

extension Date: LMDBCodable {
    /// Seconds since the reference date, encoded as a `Double`: exact, and
    /// chronological in byte order.
    public var encodedByteCount: Int { 8 }

    public func encode(into output: inout OutputRawSpan) {
        timeIntervalSinceReferenceDate.encode(into: &output)
    }

    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        do {
            self.init(timeIntervalSinceReferenceDate: try Double(lmdbBytes: bytes))
        } catch {
            throw LMDBDecodingError(Self.self, byteCount: bytes.byteCount, reason: error.reason)
        }
    }
}

// MARK: - Bool

extension Bool: LMDBCodable {
    public var encodedByteCount: Int { 1 }

    public func encode(into output: inout OutputRawSpan) {
        output.append(self ? 1 : 0)
    }

    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        try expect(bytes, count: 1, for: Self.self)
        switch bytes.load(fromByteOffset: 0, as: UInt8.self) {
        case 0: self = false
        case 1: self = true
        case let other:
            throw LMDBDecodingError(Self.self, byteCount: 1, reason: "byte \(other) is neither 0 nor 1")
        }
    }
}

// MARK: - Strings and bytes

extension String: LMDBCodable {
    public var encodedByteCount: Int { utf8.count }

    public func encode(into output: inout OutputRawSpan) {
        output.append(contentsOf: utf8Span.span.bytes)
    }

    /// Passes the string's own UTF-8 storage, without copying.
    public func withEncodedBytes<Result, Failure: Error>(
        _ body: (RawSpan) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(utf8Span.span.bytes)
    }

    /// Decodes UTF-8, throwing on invalid sequences rather than replacing
    /// them.
    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        do throws(UTF8.ValidationError) {
            self.init(copying: try UTF8Span(validating: Span<UInt8>(viewing: bytes)))
        } catch {
            throw LMDBDecodingError(Self.self, byteCount: bytes.byteCount, reason: "invalid UTF-8: \(error)")
        }
    }
}

extension Array: LMDBEncodable where Element == UInt8 {
    public var encodedByteCount: Int { count }

    public func encode(into output: inout OutputRawSpan) {
        output.append(contentsOf: self)
    }

    /// Passes the array's own storage, without copying.
    public func withEncodedBytes<Result, Failure: Error>(
        _ body: (RawSpan) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(span.bytes)
    }
}

extension Array: LMDBDecodable where Element == UInt8 {
    public init(lmdbBytes bytes: RawSpan) {
        self.init(bytes)
    }
}

extension Data: LMDBCodable {
    public var encodedByteCount: Int { count }

    public func encode(into output: inout OutputRawSpan) {
        output.append(contentsOf: self)
    }

    /// Passes the data's own storage, without copying.
    public func withEncodedBytes<Result, Failure: Error>(
        _ body: (RawSpan) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(bytes)
    }

    public init(lmdbBytes bytes: RawSpan) {
        self.init(bytes)
    }
}

extension UUID: LMDBCodable {
    public var encodedByteCount: Int { 16 }

    public func encode(into output: inout OutputRawSpan) {
        let u = uuid
        let bytes: InlineArray<16, UInt8> = [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]
        output.append(bytes, as: InlineArray<16, UInt8>.self)
    }

    public init(lmdbBytes bytes: RawSpan) throws(LMDBDecodingError) {
        try expect(bytes, count: 16, for: Self.self)
        let b = bytes.load(fromByteOffset: 0, as: InlineArray<16, UInt8>.self)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                         b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

// MARK: - Helpers

/// Throws unless `bytes` is exactly `count` bytes long.
private func expect<T>(_ bytes: RawSpan, count: Int, for type: T.Type) throws(LMDBDecodingError) {
    guard bytes.byteCount == count else {
        throw LMDBDecodingError(type, byteCount: bytes.byteCount, reason: "expected \(count) bytes")
    }
}
