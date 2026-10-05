import Foundation

/// Transient SDK input credits, separate from retained typed results and
/// native input leases. Conservative array capacity reservations are policy
/// accounting; caller inputs and allocator/RSS are not included.
let rustViewStateInputs = RustRetainedStorage(maximumBytes: 32 * 1024 * 1024, maximumOwners: 256)
let rustViewStateMaximumBytes = 4 * 1024 * 1024
let rustViewStateMaximumRecords = 4096

struct RustEncodedViewState: Sendable {
    let bytes: [UInt8]
    let credit: RustStorageCredit
}

private struct ViewStateJSON {
    var count = 0
    var bytes: [UInt8]?
    mutating func byte(_ byte: UInt8) throws {
        guard count < rustViewStateMaximumBytes else { throw RustAdmission.outputLimit }
        count += 1
        bytes?.append(byte)
    }
    mutating func literal(_ value: String) throws { for byte in value.utf8 { try self.byte(byte) } }
    mutating func number(_ value: Int64) throws { try literal(String(value)) }
    mutating func string(_ value: String) throws {
        try byte(34)
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        for (index, value) in value.utf8.enumerated() {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            switch value {
            case 34, 92: try byte(92); try byte(value)
            case 0...31:
                try literal("\\u00"); try byte(hex[Int(value >> 4)]); try byte(hex[Int(value & 15)])
            default: try byte(value)
            }
        }
        try byte(34)
    }
    mutating func document(_ value: RustViewStateDocument) throws {
        try literal("{\"formatVersion\":1,\"traceSHA256\":"); try string(value.traceSHA256)
        try literal(",\"flags\":[")
        for (index, flag) in value.flags.enumerated() {
            try Task.checkCancellation()
            if index != 0 { try byte(44) }
            try literal("{\"id\":"); try number(flag.id)
            try literal(",\"timestampNs\":"); try number(flag.timestampNs)
            try literal(",\"label\":"); try string(flag.label)
            try literal(",\"colorIndex\":"); try number(flag.colorIndex); try byte(125)
        }
        try literal("],\"marks\":[")
        for (index, mark) in value.marks.enumerated() {
            try Task.checkCancellation()
            if index != 0 { try byte(44) }
            try literal("{\"id\":"); try number(mark.id)
            try literal(",\"range\":{\"startNs\":"); try number(mark.range.startNs)
            try literal(",\"endNs\":"); try number(mark.range.endNs)
            try literal("},\"label\":"); try string(mark.label)
            try literal(",\"colorIndex\":"); try number(mark.colorIndex)
            try literal(",\"isPersistent\":"); try literal(mark.isPersistent ? "true}" : "false}")
        }
        try literal("],\"favoriteTrackIDs\":")
        if let favorites = value.favoriteTrackIDs {
            try byte(91)
            for (index, favorite) in favorites.enumerated() {
                try Task.checkCancellation()
                if index != 0 { try byte(44) }
                try string(favorite)
            }
            try byte(93)
        } else { try literal("null") }
        try byte(125)
    }
}

enum RustViewStateEncoder {
    @concurrent
    static func selection(_ selection: RustViewStateMigrationSelection, storage: RustRetainedStorage = rustViewStateInputs) async throws -> RustEncodedViewState {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        let credit = try storage.reserve(256)
        let bytes = Array(selection.digest.utf8)
        guard bytes.count == 64, bytes.capacity <= credit.bytes else { throw RustAdmission.outputLimit }
        try Task.checkCancellation()
        return RustEncodedViewState(bytes: bytes, credit: credit)
    }
    @concurrent
    static func encode(_ document: RustViewStateDocument, storage: RustRetainedStorage = rustViewStateInputs) async throws -> RustEncodedViewState {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard document.traceSHA256.utf8.count == 64,
              document.traceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              document.flags.count <= rustViewStateMaximumRecords,
              document.marks.count <= rustViewStateMaximumRecords - document.flags.count,
              (document.favoriteTrackIDs?.count ?? 0) <= rustViewStateMaximumRecords else { throw RustAdmission.invalidInput }
        for flag in document.flags {
            try Task.checkCancellation()
            guard flag.label.utf8.count <= 4096 else { throw RustAdmission.invalidInput }
        }
        for mark in document.marks {
            try Task.checkCancellation()
            guard mark.label.utf8.count <= 4096 else { throw RustAdmission.invalidInput }
        }
        for favorite in document.favoriteTrackIDs ?? [] {
            try Task.checkCancellation()
            guard favorite.utf8.count <= 4096 else { throw RustAdmission.invalidInput }
        }
        // Count escaping overhead before any output array allocation. The same
        // writer performs both passes, including Int64.min and embedded NUL.
        var measure = ViewStateJSON()
        try measure.document(document)
        let reserved = measure.count * 2 + 128
        let credit = try storage.reserve(reserved)
        var output = ViewStateJSON(bytes: [])
        output.bytes!.reserveCapacity(measure.count)
        guard output.bytes!.capacity <= reserved else { throw RustAdmission.outputLimit }
        try output.document(document)
        guard output.count == measure.count, let bytes = output.bytes, bytes.capacity <= reserved else { throw RustAdmission.outputLimit }
        try Task.checkCancellation()
        return RustEncodedViewState(bytes: bytes, credit: credit)
    }
}
