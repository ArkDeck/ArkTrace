import Foundation

func time(_ nanoseconds: Int64) -> String {
    if nanoseconds >= 1_000_000_000 {
        return (Double(nanoseconds) / 1_000_000_000).formatted(
            .number.precision(.fractionLength(3))
        ) + " s"
    }
    if nanoseconds >= 1_000_000 {
        return (Double(nanoseconds) / 1_000_000).formatted(
            .number.precision(.fractionLength(3))
        ) + " ms"
    }
    if nanoseconds >= 1_000 {
        return (Double(nanoseconds) / 1_000).formatted(
            .number.precision(.fractionLength(3))
        ) + " µs"
    }
    return "\(nanoseconds) ns"
}

func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
