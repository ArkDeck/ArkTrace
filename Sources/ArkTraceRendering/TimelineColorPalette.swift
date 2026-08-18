// Portions of this file are a Swift port of the timeline color logic in
// openharmony/developtools_smartperf_host, taken at the revision pinned in
// ThirdParty/TraceStreamer/source-lock.json and licensed under Apache-2.0:
// ide/src/trace/component/trace/base/ColorUtils.ts and Utils.getStateColor.
// See THIRD_PARTY_NOTICES.md and docs/DESIGN.md §13.5.

import ArkTraceCore
import CoreGraphics

/// A resolved sRGB fill.
///
/// Deliberately a value type rather than an `NSColor`: the renderer batches
/// every primitive that shares a fill into one path, so a fill has to be a
/// well-behaved `Hashable` key, and the palette stays unit-testable without
/// AppKit. The components are the exact bytes of the upstream hex literal, so
/// a fill is appearance-independent — the palette is a data encoding, not a
/// theme.
package struct TimelineColor: Hashable, Sendable, Comparable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses the `#rgb` / `#rrggbb` literals the upstream palette is written
    /// in, so the Swift table can be diffed against `ColorUtils.ts` verbatim.
    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = Array(hex.dropFirst())
        let expanded: [Character]
        switch digits.count {
        case 3: expanded = digits.flatMap { [$0, $0] }
        case 6: expanded = digits
        default: return nil
        }
        var components: [UInt8] = []
        components.reserveCapacity(3)
        for index in stride(from: 0, to: 6, by: 2) {
            guard let value = UInt8(String(expanded[index...(index + 1)]), radix: 16)
            else { return nil }
            components.append(value)
        }
        self.init(red: components[0], green: components[1], blue: components[2])
    }

    public static let black = TimelineColor(red: 0, green: 0, blue: 0)
    public static let white = TimelineColor(red: 255, green: 255, blue: 255)

    public var cgColor: CGColor {
        CGColor(
            srgbRed: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: 1
        )
    }

    public func cgColor(alpha: Double) -> CGColor {
        CGColor(
            srgbRed: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: min(1, max(0, alpha))
        )
    }

    /// Upstream `ColorUtils.funcTextColor`: the same 0.299/0.587/0.114 gray
    /// level and the same `>= 100` cut. This is not cosmetic — most of the
    /// palette is light enough that a fixed white label is unreadable on it.
    public var preferredLabelColor: TimelineColor {
        let grayLevel = Double(red) * 0.299 + Double(green) * 0.587 + Double(blue) * 0.114
        return grayLevel >= 100 ? .black : .white
    }

    /// Total order used to keep batched fills in a deterministic paint order.
    public static func < (lhs: TimelineColor, rhs: TimelineColor) -> Bool {
        (lhs.red, lhs.green, lhs.blue) < (rhs.red, rhs.green, rhs.blue)
    }
}

/// Upstream-aligned trace palette.
///
/// SmartPerf Host does not color a slice by its kind; it hashes the slice's
/// identity into a fixed twenty-entry palette, so the same function keeps the
/// same color across rows, traces and sessions. ArkTrace reuses the pinned
/// upstream parser, so it reuses the pinned upstream palette too: a slice gets
/// the same color in either tool.
///
/// Ported from `ide/src/trace/component/trace/base/ColorUtils.ts` at the
/// revision pinned in `ThirdParty/TraceStreamer/source-lock.json`
/// (`447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`, Apache-2.0). The hash is a
/// byte-exact port including the two details that make the upstream result
/// differ from textbook FNV-1a; see ``hash(_:modulus:)``.
///
/// AT-RENDER-008 is the normative requirement; DESIGN §13.5 records which
/// upstream function each entry point corresponds to and which two colorings
/// are ArkTrace extensions rather than parity items.
package enum TimelinePalette {
    /// Upstream `ColorUtils.FUNC_COLOR_B`, which the pinned revision aliases
    /// as both `MD_PALETTE` (CPU slices, by process) and `FUNC_COLOR` (named
    /// slices, by name). Kept as hex literals so the table can be diffed
    /// against upstream character for character; `TimelinePaletteTests` locks
    /// both the count and the parsed components.
    public static let funcColorLiterals: [String] = [
        "#23b0e7", "#aa4fba", "#4ca694", "#8d9171", "#ebc247",
        "#8a8a8b", "#78aec2", "#FF0066", "#a16a40", "#e05b52",
        "#7a9160", "#9fafc4", "#9bb87a", "#8091D0", "#c2cc66",
        "#a94eb9", "#8983B5", "#B9A683", "#40b3e7", "#789876",
    ]

    public static let funcColors: [TimelineColor] = funcColorLiterals.compactMap {
        TimelineColor(hex: $0)
    }

    /// Upstream `ColorUtils.GREY_COLOR`, used where upstream has no identity
    /// to hash.
    public static let greyColor = TimelineColor(red: 0xF0, green: 0xF0, blue: 0xF0)

    /// Upstream `ColorUtils.hash`.
    ///
    /// Two upstream details decide the result and are reproduced exactly:
    ///
    /// 1. The FNV-1a offset basis is masked with `0xfffffff` — seven `f`s, not
    ///    eight — so the basis loses its top nibble and the first round starts
    ///    from `0x011c9dc5`.
    /// 2. Each round multiplies in JavaScript `Number` arithmetic and only
    ///    then truncates to Int32. The product needs up to 55 bits, so its low
    ///    bits are rounded away *before* the truncation. Reproducing that
    ///    rounding is what keeps this in step with upstream; a faithful 32-bit
    ///    integer FNV-1a would diverge on almost every real slice name.
    ///
    /// `modulus` is upstream's `max` parameter, renamed because `max` would
    /// shadow the standard function.
    public static func hash(_ value: String, modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        return Int(UInt64(fnvHash(value.utf16).magnitude) % UInt64(modulus))
    }

    /// Upstream `ColorUtils.hashFunc`: `hash` over the name with every ASCII
    /// digit removed, offset by the call depth. Stripping digits is what makes
    /// `ipc::42` and `ipc::43` share a color instead of landing on unrelated
    /// palette entries.
    public static func hashFunc(_ value: String, depth: Int, modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let stripped = value.utf16.lazy.filter { !(0x30...0x39).contains($0) }
        let magnitude = UInt64(fnvHash(stripped).magnitude)
        return Int((magnitude + UInt64(Swift.max(0, depth))) % UInt64(modulus))
    }

    /// Upstream `ColorUtils.colorForName`: named-row identity, no digit
    /// stripping.
    public static func color(forName name: String) -> TimelineColor {
        funcColors[hash(name, modulus: funcColors.count)]
    }

    /// Upstream `ColorUtils.colorForTid`, which hashes the decimal identity —
    /// callers pass the process id when there is one, exactly as upstream's
    /// `colorForThread` does.
    public static func color(forProcessOrThreadID identity: Int64) -> TimelineColor {
        funcColors[hash(String(identity), modulus: funcColors.count)]
    }

    /// Upstream `ColorUtils.JANK_COLOR`, ported verbatim. Only indices 0, 2 and
    /// 3 are reachable because `jank_tag` is only ever 0, 1 or 3.
    static let jankColors: [TimelineColor] = [
        "#42A14D", "#C0CE85", "#FF651D", "#E8BE44", "#009DFA", "#E97978",
    ].compactMap { TimelineColor(hex: $0) }

    /// `jank_tag` 1 → orange, 3 → yellow, otherwise the normal frame colour.
    public static func jankColor(tag: Int64) -> TimelineColor {
        guard jankColors.count >= 4 else { return greyColor }
        switch tag {
        case 1: return jankColors[2]
        case 3: return jankColors[3]
        default: return jankColors[0]
        }
    }

    /// Upstream `ProcedureWorkerFunc`: `FUNC_COLOR[hashFunc(name, depth, n)]`.
    public static func color(forSliceName name: String, depth: Int = 0) -> TimelineColor {
        funcColors[hashFunc(name, depth: depth, modulus: funcColors.count)]
    }

    /// Identity color for a whole track, drawn from the same palette but
    /// **not** through ``hash(_:modulus:)``.
    ///
    /// Upstream's hash has to stay byte-exact because its whole purpose is
    /// reproducing upstream's colors, and it distributes badly over short keys
    /// that differ only near the end: `cpu:0` and `cpu:1` collide, and
    /// `thread-state:4` through `thread-state:9` all land on one entry. Track
    /// bands are ArkTrace's own encoding with no upstream counterpart to match,
    /// so they use a correctly-mixed 64-bit FNV-1a instead and adjacent tracks
    /// actually separate. Keep the two hashes distinct: unifying them would
    /// either break upstream parity or put every thread band on one color.
    public static func trackIdentityColor(_ key: String) -> TimelineColor {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
        return funcColors[Int(hash % UInt64(funcColors.count))]
    }

    /// Upstream `Utils.getStateColor` over the exact raw state string, with an
    /// ArkTrace fallback through the normalized state.
    ///
    /// The raw chain is upstream's, verbatim. The fallback exists because
    /// ArkTrace's normalizer also accepts spellings upstream never sees
    /// (`RUNNABLE`, `READY`, `SLEEPING`, `BLOCKED`, `UNINTERRUPTIBLE`); those
    /// are the same states, and dropping them into upstream's catch-all would
    /// paint a sleeping thread the same color as a genuinely unknown one.
    public static func stateColor(
        raw: String?,
        normalized: TraceThreadState? = nil
    ) -> TimelineColor {
        if let raw, let exact = upstreamStateColors[raw] { return exact }
        switch normalized {
        case .running: return unknownStateFallback(hex: "#467b3b")
        case .runnable: return unknownStateFallback(hex: "#a0b84d")
        case .sleeping: return unknownStateFallback(hex: "#e0e0e0")
        case .blocked: return unknownStateFallback(hex: "#f19b38")
        // Upstream has no branch for `T`; it lands in the catch-all, and so
        // does ArkTrace's `stopped`.
        case .stopped, .none: return unknownStateColor
        }
    }

    /// Upstream `Utils.getStateColor`'s catch-all.
    public static let unknownStateColor = TimelineColor(red: 0xFF, green: 0x6E, blue: 0x40)

    private static func unknownStateFallback(hex: String) -> TimelineColor {
        TimelineColor(hex: hex) ?? unknownStateColor
    }

    /// The upstream chain, flattened. Keys are the exact strings upstream
    /// compares against, so this table is directly checkable against
    /// `Utils.getStateColor`.
    private static let upstreamStateColors: [String: TimelineColor] = [
        "D-NIO": TimelineColor(red: 0x79, green: 0x55, blue: 0x48),
        "DK-NIO": TimelineColor(red: 0x79, green: 0x55, blue: 0x48),
        "D-IO": TimelineColor(red: 0xF1, green: 0x9B, blue: 0x38),
        "DK-IO": TimelineColor(red: 0xF1, green: 0x9B, blue: 0x38),
        "D": TimelineColor(red: 0xF1, green: 0x9B, blue: 0x38),
        "DK": TimelineColor(red: 0xF1, green: 0x9B, blue: 0x38),
        "R": TimelineColor(red: 0xA0, green: 0xB8, blue: 0x4D),
        "R+": TimelineColor(red: 0xA0, green: 0xB8, blue: 0x4D),
        "R-B": TimelineColor(red: 0x87, green: 0xCE, blue: 0xFA),
        "I": TimelineColor(red: 0x67, green: 0x3A, blue: 0xB7),
        "Running": TimelineColor(red: 0x46, green: 0x7B, blue: 0x3B),
        "S": TimelineColor(red: 0xE0, green: 0xE0, blue: 0xE0),
    ]

    /// The shared inner loop of `hash` and `hashFunc`.
    ///
    /// `Double(hash)` is exact (`|hash| < 2^31`), the product is integer-valued
    /// and below `2^55` so the `Int64` conversion cannot trap, and
    /// `truncatingIfNeeded` is precisely JavaScript's `ToInt32`.
    private static func fnvHash(_ units: some Sequence<UInt16>) -> Int32 {
        var hash = Int32(0x011C_9DC5)
        for unit in units {
            hash ^= Int32(unit)
            hash = Int32(truncatingIfNeeded: Int64(Double(hash) * 16_777_619))
        }
        return hash
    }
}

/// Resolves an aggregate density bucket to its fill.
///
/// The band borrows the fill of the event that occupies the bucket longest, so
/// an overview is a low-resolution picture of the same trace rather than a
/// differently-coloured one: zooming in sharpens the blocks instead of
/// recolouring them, and a process keeps the colour it has at detail level and
/// in SmartPerf Host. When the source has no per-event identity — counter
/// series, whose samples upstream draws as an area chart with no per-sample
/// fill — the band falls back to the track's own identity colour, which is
/// what every band used to use.
package enum TimelineDensityPalette {
    public static func color(
        for bucket: TraceDensityBucket,
        fallback: @autoclosure () -> TimelineColor
    ) -> TimelineColor {
        switch bucket.dominant {
        case .processOrThread(let identity):
            TimelinePalette.color(forProcessOrThreadID: identity)
        case .name(let name):
            TimelinePalette.color(forSliceName: name)
        case .threadState(let raw):
            TimelinePalette.stateColor(raw: raw)
        case .jank(let tag):
            TimelinePalette.jankColor(tag: tag)
        case nil:
            fallback()
        }
    }
}

/// Resolves a snapshot primitive to its fill.
///
/// Kept separate from `TimelineNSView` so the mapping is testable without a
/// window, and separate from `TimelinePalette` so the upstream port stays a
/// literal port with no ArkTrace policy mixed in.
package enum TimelineDetailPalette {
    /// The fill upstream would give this event.
    ///
    /// - CPU slices take the running process's identity (`colorForThread`:
    ///   process id when there is one, thread id otherwise, and upstream's
    ///   `tid || 0` when the row carries neither).
    /// - Thread states take the fixed state palette, keyed on the exact raw
    ///   upstream state string that ArkTrace preserves alongside its
    ///   normalized value.
    /// - Everything else — named slices and counter series — takes the
    ///   digit-stripped name hash, which is what upstream's function rows use.
    ///   Counters are ArkTrace's own extension of that rule: upstream draws
    ///   them as area charts with no comparable per-sample fill, and hashing
    ///   the series name at least gives each series a stable identity.
    public static func color(for detail: TimelineDetailPrimitive) -> TimelineColor {
        // The inspector's type is the unambiguous discriminator. `category` is
        // overloaded across sources -- a thread state's category is its
        // normalized state name, while a named slice's is whatever the trace
        // called it -- so it is only consulted when no inspector is attached.
        switch detail.inspector?.type {
        case .cpuSlice:
            return processColor(pid: detail.inspector?.pid, tid: detail.inspector?.tid)
        case .threadState:
            return TimelinePalette.stateColor(
                raw: detail.inspector?.state ?? detail.label,
                normalized: normalizedState(for: detail.category)
            )
        case .frame:
            // Upstream's JANK_COLOR: index 0 normal, 2 for jank_tag 1, 3 for
            // jank_tag 3 (`ProcedureWorkerJank.ts`). Colour is a second signal
            // only -- the label and Inspector say "jank" in words (AT-APP-011).
            return TimelinePalette.jankColor(tag: detail.jankTag)
        case .namedSlice, .counter:
            return nameColor(for: detail)
        case nil:
            if detail.category == "cpu" {
                return processColor(pid: nil, tid: nil)
            }
            if let normalized = normalizedState(for: detail.category) {
                return TimelinePalette.stateColor(raw: detail.label, normalized: normalized)
            }
            return nameColor(for: detail)
        }
    }

    /// Upstream `colorForThread`: the process id when the row has one, the
    /// thread id otherwise, and upstream's `tid || 0` when it has neither.
    private static func processColor(pid: Int64?, tid: Int64?) -> TimelineColor {
        let pid = pid ?? 0
        let tid = tid ?? 0
        return TimelinePalette.color(forProcessOrThreadID: pid > 0 ? pid : tid)
    }

    private static func nameColor(for detail: TimelineDetailPrimitive) -> TimelineColor {
        guard let name = detail.inspector?.name ?? detail.label, !name.isEmpty
        else { return TimelinePalette.greyColor }
        return TimelinePalette.color(forSliceName: name)
    }

    private static func normalizedState(for category: String?) -> TraceThreadState? {
        guard let category else { return nil }
        return TraceThreadState(rawValue: category)
    }
}
