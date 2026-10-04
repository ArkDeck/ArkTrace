import Foundation

/// Foundation's keyed containers collapse duplicate keys. Check raw typed
/// response bytes first, including differently escaped spellings of a key.
/// This scanner borrows Data's storage and never materializes value strings.
/// Key admission is bounded logical storage, not a Foundation allocator/RSS
/// measurement. The typed decoder remains responsible for values and schema.
enum RustJSONShape {
    static func validate(_ data: Data, staging: RustRetainedStorage, integerNumbersOnly: Bool = false,
                         maximumInputBytes: Int = 16 * 1024 * 1024, maximumArrayElements: Int = 100_000) throws {
        guard (1...(64 * 1024 * 1024)).contains(maximumInputBytes), (1...1_000_000).contains(maximumArrayElements),
              (1...maximumInputBytes).contains(data.count) else { throw RustAdmission.invalidBuffer }
        let credit = try staging.reserve(min(data.count, 16 * 1024) * 2 + 4096)
        defer { withExtendedLifetime(credit) {} }
        let scanner = Scanner(data, integerNumbersOnly: integerNumbersOnly, maximumArrayElements: maximumArrayElements)
        try scanner.value(depth: 0)
        try scanner.whitespace()
        guard scanner.offset == data.count else { throw RustAdmission.invalidBuffer }
    }

    private final class Scanner {
        let data: Data
        var offset = 0
        private var activeKeyBytes = 0
        private let integerNumbersOnly: Bool
        private let maximumArrayElements: Int
        init(_ data: Data, integerNumbersOnly: Bool, maximumArrayElements: Int) {
            self.data = data; self.integerNumbersOnly = integerNumbersOnly; self.maximumArrayElements = maximumArrayElements
        }
        private var next: UInt8? { offset < data.count ? data[data.startIndex + offset] : nil }

        private func advance() throws {
            offset += 1
            if offset.isMultiple(of: 1024) { try Task.checkCancellation() }
        }
        func whitespace() throws {
            while let byte = next, byte == 32 || byte == 9 || byte == 10 || byte == 13 { try advance() }
        }
        private func take(_ byte: UInt8) throws {
            guard next == byte else { throw RustAdmission.invalidBuffer }
            try advance()
        }
        func value(depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 32 else { throw RustAdmission.outputLimit }
            try whitespace()
            guard let byte = next else { throw RustAdmission.invalidBuffer }
            switch byte {
            case 123: try object(depth: depth + 1)
            case 91: try array(depth: depth + 1)
            case 34: _ = try string(key: false)
            case 116: try literal([116, 114, 117, 101])
            case 102: try literal([102, 97, 108, 115, 101])
            case 110: try literal([110, 117, 108, 108])
            case 45, 48...57: try number()
            default: throw RustAdmission.invalidBuffer
            }
        }
        private func object(depth: Int) throws {
            try take(123); try whitespace()
            if next == 125 { try advance(); return }
            var keys = Set<String>()
            var ownKeyBytes = 0
            defer { activeKeyBytes -= ownKeyBytes }
            while true {
                guard keys.count < 32 else { throw RustAdmission.outputLimit }
                let key = try string(key: true)!
                let count = key.utf8.count
                guard count <= 16 * 1024 - activeKeyBytes else { throw RustAdmission.outputLimit }
                guard keys.insert(key).inserted else { throw RustAdmission.invalidBuffer }
                activeKeyBytes += count; ownKeyBytes += count
                try whitespace(); try take(58); try value(depth: depth); try whitespace()
                if next == 125 { try advance(); return }
                try take(44); try whitespace()
            }
        }
        private func array(depth: Int) throws {
            try take(91); try whitespace()
            if next == 93 { try advance(); return }
            var count = 0
            while true {
                guard count < maximumArrayElements else { throw RustAdmission.outputLimit }
                try value(depth: depth); count += 1; try whitespace()
                if next == 93 { try advance(); return }
                try take(44); try whitespace()
            }
        }
        private func string(key: Bool) throws -> String? {
            let start = offset
            try take(34)
            while let byte = next {
                guard byte >= 32 else { throw RustAdmission.invalidBuffer }
                try advance()
                if key, offset - start > 256 { throw RustAdmission.outputLimit }
                if byte == 34 {
                    guard key else { return nil }
                    let token = data.subdata(in: (data.startIndex + start)..<(data.startIndex + offset))
                    do { return try JSONDecoder().decode(String.self, from: token) }
                    catch { throw RustAdmission.invalidBuffer }
                }
                if byte == 92 {
                    guard let escape = next else { throw RustAdmission.invalidBuffer }
                    try advance()
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard let digit = next, (48...57).contains(digit) || (65...70).contains(digit) || (97...102).contains(digit) else {
                                throw RustAdmission.invalidBuffer
                            }
                            try advance()
                        }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) {
                        throw RustAdmission.invalidBuffer
                    }
                }
            }
            throw RustAdmission.invalidBuffer
        }
        private func literal(_ expected: [UInt8]) throws {
            for byte in expected { try take(byte) }
        }
        private func digits() throws {
            guard let byte = next, (48...57).contains(byte) else { throw RustAdmission.invalidBuffer }
            while let byte = next, (48...57).contains(byte) { try advance() }
        }
        private func number() throws {
            let start = offset
            if next == 45 { try advance() }
            if next == 48 { try advance() } else { try digits() }
            // These typed cold schemas have no floating fields.
            // Foundation would otherwise accept 1.0/1e0 as an integer.
            if integerNumbersOnly, next == 46 || next == 101 || next == 69 { throw RustAdmission.invalidBuffer }
            if next == 46 { try advance(); try digits() }
            if next == 101 || next == 69 {
                try advance()
                if next == 43 || next == 45 { try advance() }
                try digits()
            }
            guard offset - start <= 128 else { throw RustAdmission.outputLimit }
        }
    }
}
