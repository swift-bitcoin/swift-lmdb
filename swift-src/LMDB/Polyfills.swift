#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Adapted from the OptimalDigest poc (Sources/OptimalDigest/Polyfills/), which
// took them from swift-bitcoin (src/bitcoin-crypto/codec/Binary/, develop
// branch). OptimalDigest's local changes are kept: `unsafe` markers for strict
// memory safety, internal access (two modules adding the same public
// extension to a standard library type would make every call ambiguous in code
// importing both), and the memory-model fix in `[UInt8](_: RawSpan)`.
//
// Local change here: `append(contentsOf:)` gains a `RawSpan` overload, for
// encoding `String` (whose `utf8Span` is a span, not `ContiguousBytes`). Only
// the polyfills this module uses are included.

extension OutputRawSpan {
    /// Appends the bytes of `data`. Traps if they do not fit.
    mutating func append<D: ContiguousBytes>(contentsOf data: D) {
        unsafe data.withUnsafeBytes { source in
            unsafe append(copying: source)
        }
    }

    /// Appends the bytes of `bytes`. Traps if they do not fit.
    mutating func append(contentsOf bytes: RawSpan) {
        bytes.withUnsafeBytes { source in
            unsafe append(copying: source)
        }
    }

    private mutating func append(copying source: UnsafeRawBufferPointer) {
        guard unsafe !source.isEmpty else { return }
        unsafe withUnsafeMutableBytes { target, initializedCount in
            precondition(
                target.count - initializedCount >= source.count,
                "Out of bounds: OutputRawSpan has insufficient capacity.")
            unsafe (target.baseAddress! + initializedCount)
                .copyMemory(from: source.baseAddress!, byteCount: source.count)
            initializedCount += source.count
        }
    }
}

extension Data {
    /// Creates data from a raw span, copying its bytes.
    init(_ span: RawSpan) {
        self = span.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return Data() }
            return unsafe Data(bytes: base, count: pointer.count)
        }
    }
}

extension Array where Element == UInt8 {
    /// Creates an array from a raw span, copying its bytes.
    ///
    /// Reads through `UnsafeRawBufferPointer`'s raw-load `Collection`
    /// conformance rather than `assumingMemoryBound(to: UInt8.self)`: the
    /// bytes may be bound to another type, and reading them through a typed
    /// `UInt8` pointer would be undefined behaviour (OptimalDigest's fix).
    init(_ span: RawSpan) {
        self = span.withUnsafeBytes { pointer in unsafe Array(pointer) }
    }
}
