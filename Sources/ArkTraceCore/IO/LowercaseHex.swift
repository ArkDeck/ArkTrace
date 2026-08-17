/// Canonical lowercase-hex rendering for digests and identity strings.
///
/// Every SHA-256 identity in the product (cache keys, parser identity,
/// executable identity, schema fingerprints) is exactly 64 lowercase hex
/// characters. This helper is the single production implementation; an
/// independent reference implementation lives in the Core tests to
/// cross-validate the byte-for-byte output.
private let lowercaseHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

extension Sequence<UInt8> {
    /// Lowercase hexadecimal rendering of the byte sequence, two characters
    /// per byte, with no separators. A 32-byte digest yields exactly 64
    /// characters.
    package func lowercaseHexString() -> String {
        var output = [UInt8]()
        output.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            output.append(lowercaseHexDigits[Int(byte >> 4)])
            output.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
