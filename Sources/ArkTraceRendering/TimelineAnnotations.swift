import ArkTraceCore
import CoreGraphics

/// User-placed marks on the timeline: point bookmarks (flags) and interval
/// bookmarks (A/B marks).
///
/// Deliberately **not** part of ``TimelineSnapshot``. A snapshot is an
/// immutable bounded query result whose lifetime is one viewport generation
/// (AT-RENDER-002); annotations are user state that must survive every pan,
/// zoom and reload of that session. Folding them into the snapshot would make
/// them a function of the query, which is exactly wrong.
public struct TimelineFlag: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    /// Trace-relative nanoseconds (AT-TIME-001).
    public var timestampNs: Int64
    public var label: String
    /// Index into the annotation palette rather than a raw colour, so a flag
    /// stays legible if the palette is re-themed.
    public var colorIndex: Int

    public init(id: Int, timestampNs: Int64, label: String, colorIndex: Int) {
        self.id = id
        self.timestampNs = timestampNs
        self.label = label
        self.colorIndex = colorIndex
    }

    /// A flag is an instant; range-based reveal needs a non-empty interval, so
    /// it borrows one nanosecond rather than a magic window.
    public var pointRange: TraceTimeRange {
        (try? TraceTimeRange.query(startNs: timestampNs, endNs: timestampNs + 1))
            ?? (try! TraceTimeRange.query(startNs: 0, endNs: 1))
    }
}

public struct TimelineMark: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public var range: TraceTimeRange
    public var label: String
    public var colorIndex: Int
    /// Upstream distinguishes `m` (transient) from `Shift+m` (kept). A
    /// transient mark is replaced by the next one; kept marks accumulate.
    public var isPersistent: Bool

    public init(
        id: Int,
        range: TraceTimeRange,
        label: String,
        colorIndex: Int,
        isPersistent: Bool
    ) {
        self.id = id
        self.range = range
        self.label = label
        self.colorIndex = colorIndex
        self.isPersistent = isPersistent
    }
}

public struct TimelineAnnotations: Hashable, Codable, Sendable {
    public var flags: [TimelineFlag]
    public var marks: [TimelineMark]

    public init(flags: [TimelineFlag] = [], marks: [TimelineMark] = []) {
        self.flags = flags
        self.marks = marks
    }

    public var isEmpty: Bool { flags.isEmpty && marks.isEmpty }

    /// Flags in time order. Navigation and rendering both use this, so a flag
    /// added out of order still behaves as if it had been placed in sequence.
    public var orderedFlags: [TimelineFlag] {
        flags.sorted {
            if $0.timestampNs != $1.timestampNs {
                return $0.timestampNs < $1.timestampNs
            }
            return $0.id < $1.id
        }
    }

    public var orderedMarks: [TimelineMark] {
        marks.sorted {
            if $0.range.startNs != $1.range.startNs {
                return $0.range.startNs < $1.range.startNs
            }
            return $0.id < $1.id
        }
    }

    /// First flag strictly after `timestampNs`, wrapping to the first flag so
    /// repeated presses cycle rather than dead-ending at the last one.
    public func flag(after timestampNs: Int64) -> TimelineFlag? {
        let ordered = orderedFlags
        return ordered.first { $0.timestampNs > timestampNs } ?? ordered.first
    }

    public func flag(before timestampNs: Int64) -> TimelineFlag? {
        let ordered = orderedFlags
        return ordered.last { $0.timestampNs < timestampNs } ?? ordered.last
    }

    public func mark(after timestampNs: Int64) -> TimelineMark? {
        let ordered = orderedMarks
        return ordered.first { $0.range.startNs > timestampNs } ?? ordered.first
    }

    public func mark(before timestampNs: Int64) -> TimelineMark? {
        let ordered = orderedMarks
        return ordered.last { $0.range.startNs < timestampNs } ?? ordered.last
    }
}

/// Colours for user annotations, deliberately separate from the slice palette:
/// an annotation is the user's own mark on the trace and must not read as
/// another event. Small and fixed so a colour index survives a session.
package enum TimelineAnnotationPalette {
    package static let colors: [TimelineColor] = [
        TimelineColor(red: 0xE0, green: 0x3B, blue: 0x24),  // red
        TimelineColor(red: 0xF2, green: 0x99, blue: 0x0C),  // amber
        TimelineColor(red: 0x1D, green: 0x9A, blue: 0x6C),  // green
        TimelineColor(red: 0x1C, green: 0x7E, blue: 0xD6),  // blue
        TimelineColor(red: 0x8E, green: 0x44, blue: 0xAD),  // violet
        TimelineColor(red: 0x4A, green: 0x4A, blue: 0x4A),  // graphite
    ]

    /// Total over every index, so a stored colour index can never crash a
    /// render even if the palette shrinks.
    package static func color(at index: Int) -> TimelineColor {
        guard !colors.isEmpty else {
            return TimelineColor(red: 0, green: 0, blue: 0)
        }
        let wrapped = ((index % colors.count) + colors.count) % colors.count
        return colors[wrapped]
    }
}

/// Public face of the annotation palette. The palette itself stays internal —
/// callers outside the package only ever hold a colour index — but the App has
/// to draw the swatch that index stands for.
public enum TimelineAnnotationColor {
    public static var count: Int { TimelineAnnotationPalette.colors.count }

    public static func cgColor(at index: Int) -> CGColor {
        TimelineAnnotationPalette.color(at: index).cgColor
    }
}

/// What a keyboard annotation command asks the host to do. The view knows the
/// current viewport; only the host can change it, so navigation is expressed
/// as intent rather than performed in the view.
public enum TimelineAnnotationCommand: Hashable, Sendable {
    /// Bare `,` / `.` upstream: bring the nearest flag back on screen without
    /// changing which flag is "current".
    case scrollNearestFlagIntoView
    case previousFlag
    case nextFlag
    case previousMark
    case nextMark
    /// `m` / `Shift+m`: turn the current selection into a mark.
    case createMark(isPersistent: Bool)
}
