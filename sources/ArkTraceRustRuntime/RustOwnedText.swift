import Foundation

/// An immutable UTF-8 pool. Record and text views keep this owner and its
/// storage credit alive; there is no public mutable array or raw pointer.
final class RustTextStorage: Sendable {
    let bytes: [UInt8]
    let credit: RustStorageCredit
    init(bytes: [UInt8], credit: RustStorageCredit) {
        precondition(credit.bytes >= bytes.capacity)
        self.bytes = bytes
        self.credit = credit
    }
}

/// A UTF-8 text view that retains its SDK owner. Borrowing is synchronous and
/// nonescaping. An explicit String copy belongs to the caller, independently
/// of the SDK's packed-storage credit.
public struct RustOwnedText: Sendable {
    private let storage: RustTextStorage
    private let range: Range<Int>
    init(storage: RustTextStorage, range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= storage.bytes.count)
        self.storage = storage
        self.range = range
    }
    public var utf8Count: Int { range.count }

    public func withUTF8<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            // A local Array value establishes the lexical borrow lifetime.
            // This is an immutable COW reference, not a UTF-8 allocation.
            let bytes = storage.bytes
            return try body(bytes.span.extracting(range))
        }
    }

    /// Explicit caller materialization; does not expose an unowned SDK String.
    /// Keep UI formatting/copy work off MainActor, as for cold result decoding.
    @concurrent
    public func copyString() async -> String {
        precondition(!Thread.isMainThread)
        return String(decoding: storage.bytes[range], as: UTF8.self)
    }
}
