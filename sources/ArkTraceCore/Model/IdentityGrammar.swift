/// Shared grammar for hex identity strings (cache keys, digests, fingerprints).
///
/// One implementation replaces the byte-for-byte identical copies that lived
/// in Runtime and CLI plus two inline guards in the Parser. The grammar is
/// deliberately strict: ASCII `0-9a-f` only, exact length, no uppercase.
package enum ArkTraceIdentityGrammar {
    package static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

    /// Exactly 64 lowercase hex characters — the shape of every SHA-256
    /// identity in the product.
    package static func isSHA256(_ value: String) -> Bool {
        isLowercaseHex(value, count: 64)
    }
}
