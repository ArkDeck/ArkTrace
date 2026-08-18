import Foundation

/// Reads the pinned parser's own progress out of its stdout.
///
/// TraceStreamer 4.3.7 writes `\rLoadingFile:\t<n> MB\r` once per mebibyte it
/// reads, in decimal megabytes. `<n>` counts the bytes of the stream it is
/// reading, which is the file itself for an uncompressed capture -- on the
/// 265,032,803-byte reference capture the last record is `265.03 MB` -- but
/// the *decompressed* size for a compressed one, where the parser inflates to
/// a temporary file first (`zlib.htrace`: 67,837 bytes on disk, 849,657 after
/// inflation, reported as `0.85 MB`). Against the source's size that reads as
/// "at least this far", which is why ``TraceLoadingProgress`` clamps.
///
/// Records arrive split across pipe reads, so a tail with no closing `\r` is
/// held over. The held tail is bounded: a child that never emits a delimiter
/// must not be able to grow this without limit.
package struct TraceStreamerProgressScanner {
    package static let marker = "LoadingFile:"
    /// The parser reports decimal megabytes, not mebibytes -- checked against
    /// the reference capture, where the byte count and the last record agree
    /// to five significant figures.
    package static let bytesPerMegabyte = 1_000_000.0
    /// Two records are ~26 bytes. Anything past this without a delimiter is
    /// not a progress record, and keeping it would be an unbounded buffer fed
    /// by a subprocess.
    package static let residualLimit = 4_096

    private var residual = ""

    package init() {}

    /// The newest source-byte count when this chunk completed at least one
    /// record, or nil when it did not.
    package mutating func consume(_ text: String) -> Int64? {
        residual += text
        var records = residual.components(separatedBy: "\r")
        // The last piece has no delimiter yet: it may be half a record.
        residual = records.removeLast()
        if residual.utf8.count > Self.residualLimit { residual = "" }
        var newest: Int64?
        for record in records {
            guard let bytes = Self.bytes(in: record) else { continue }
            newest = bytes
        }
        return newest
    }

    static func bytes(in record: String) -> Int64? {
        guard let markerRange = record.range(of: marker) else { return nil }
        let tail = record[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(tail.prefix { $0.isNumber || $0 == "." }),
            value.isFinite, value >= 0
        else { return nil }
        // Rounded, not truncated: `265.03 * 1_000_000` is 265_029_999.999… in
        // binary, and a byte count that reads one short of the file's own size
        // would leave the bar a hair below full at the end of every parse.
        let bytes = (value * bytesPerMegabyte).rounded()
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }
}
