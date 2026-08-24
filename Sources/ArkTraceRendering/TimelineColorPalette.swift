// The colour *assignment* here is a Swift port of the timeline color logic in
// openharmony/developtools_smartperf_host, taken at the revision pinned in
// ThirdParty/TraceStreamer/source-lock.json and licensed under Apache-2.0:
// ide/src/trace/component/trace/base/ColorUtils.ts and Utils.getStateColor.
// Neither fill table is: the twenty-entry identity palette and the thread
// state table are both ArkTrace's own values sitting in upstream's structure,
// for the reasons recorded on `funcColorLiterals`, on `stateColors`, and in
// docs/DESIGN.md §13.5. `scripts/verify_palette.py` measures both.
// See THIRD_PARTY_NOTICES.md.

import ArkTraceCore
import CoreGraphics

/// A resolved sRGB fill.
///
/// Deliberately a value type rather than an `NSColor`: the renderer batches
/// every primitive that shares a fill into one path, so a fill has to be a
/// well-behaved `Hashable` key, and the palette stays unit-testable without
/// AppKit. A fill is appearance-independent, and stays so: every entry in
/// both tables clears 3:1 against `#FFFFFF` and against `#1E1E1E`, which is
/// what lets one set of values serve both appearances instead of becoming a
/// theme with two of everything.
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

/// Trace palette: upstream's assignment, ArkTrace's colours.
///
/// Both of the two tables below follow the same split -- upstream decides
/// *which* fill an event gets, ArkTrace decides what that fill is.
///
/// SmartPerf Host does not color a slice by its kind; it hashes the slice's
/// identity into a fixed twenty-entry palette, so the same function keeps the
/// same color across rows, traces and sessions. ArkTrace keeps that mechanism
/// exactly -- same hash, same identities, same slots -- and replaces only the
/// twenty values it indexes into.
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
    /// The twenty fills an identity hashes into. It fills the slot upstream's
    /// `FUNC_COLOR_B` fills -- CPU slices by process, named slices by name --
    /// but the values are ArkTrace's own, and that is a deliberate departure
    /// from parity.
    ///
    /// **The table is designed around how often each slot is actually
    /// reached**, because the reach is wildly uneven and that is what decides
    /// how the canvas looks. ``hash(_:modulus:)`` reproduces upstream's
    /// JavaScript arithmetic, where each round multiplies in the `Double`
    /// domain before truncating to `Int32`; the product needs up to 55 bits, a
    /// `Double` carries 53, so the low two bits are rounded away *before* the
    /// truncation. The magnitude is a multiple of four roughly three quarters
    /// of the time, and 20 = 4 x 5, so `magnitude % 20` collapses onto
    /// {0, 4, 8, 12, 16}. Measured over 20,000 synthetic slice names plus
    /// every pid from 1 to 19,999 (`scripts/verify_palette.py`, deterministic
    /// corpus):
    ///
    /// - slots 0, 4, 8, 12, 16 -- ~14.9% each, **74.3% together**;
    /// - slots 2, 6, 10, 14, 18 -- ~2.6% each, 12.9% together;
    /// - the ten odd slots -- ~1.3% each, 12.8% together.
    ///
    /// So five entries are the timeline's colour scheme and the other fifteen
    /// are trim. The table is built in those tiers:
    ///
    /// - **Tier A** (0/4/8/12/16) is one harmonious family: OKLCH lightness
    ///   spread 0.038, chroma 0.088, hues walking a controlled blue -> teal ->
    ///   sage -> bronze -> clay sweep. Three quarters of the pixels have to
    ///   read as one surface, not as five warning lights.
    /// - **Tier B** (2/6/10/14/18) sits between A and C. It is *not* "the same
    ///   hues one step darker" -- the whole table lives in one narrow
    ///   luminance band (below), so there is no darker step to take; B is a
    ///   second pass around the hue circle at slightly higher chroma.
    /// - **Tier C** (the odd slots) is where the remaining hues go. "Rare"
    ///   holds for *named slices* pooled over a large corpus; it does not hold
    ///   per-lane, because a trace has 6-30 processes rather than 20,000, so a
    ///   full-width CPU lane lands in Tier C often. Its chroma is therefore
    ///   capped near Tier A's (measured 0.086 vs 0.088) rather than left to
    ///   drift loud.
    /// - **Slot 5 is neutral on purpose.** `hash("0", modulus: 20) == 5`, and
    ///   ``TimelineDetailPalette`` resolves `pid ?? 0` / `tid ?? 0`, so every
    ///   CPU slice with no identity at all lands there. A grey says "nobody
    ///   knows whose this is"; the saturated wine that sat here between
    ///   2026-08-19 and 2026-08-24 said the opposite.
    ///
    /// What this replaced: a constant-chroma OKLCH ring that took, for each
    /// hue, the lightness carrying the most chroma. That rule maximises
    /// saturation and, because the sRGB cusp moves with hue, maximises
    /// lightness variance as a side effect -- Tier A came out at chroma 0.153
    /// with a lightness spread of 0.279, i.e. five maximum-chroma hues 72
    /// degrees apart strobing between L 0.46 and L 0.74. It also reported its
    /// own win on the wrong pairs: "worst adjacent pair" is *slot* adjacency,
    /// and the assignment hash scatters identities, so any two slots can abut
    /// on screen. Over all 190 pairs it measured 3.8, not 30.
    ///
    /// **There are four canvases, not two.** `windowBackgroundColor`,
    /// `controlBackgroundColor` and `textBackgroundColor` all resolve to
    /// `#FFFFFF` in Aqua and `#1E1E1E` in DarkAqua -- but `drawTracks` stripes
    /// alternate rows with `NSColor.alternatingContentBackgroundColors`, which
    /// adds `#F4F5F5` and `#292929`. Which row a track lands on is an accident
    /// of ordering, so every fill has to clear 3:1 against all four. This is
    /// not hypothetical: the striping fix and the first cut of this table
    /// shipped together, and that cut put six fills between 2.78:1 and 2.96:1
    /// against `#F4F5F5` -- including the two most common thread states --
    /// while the gate reported 0/20 because it only knew about `#FFFFFF`.
    ///
    /// | | 2026-08-19 | now |
    /// |---|---|---|
    /// | occupancy-weighted chroma | 0.154 | 0.088 |
    /// | min ΔE over all 190 pairs | 3.8 | 5.4 |
    /// | Tier A lightness spread | 0.279 | 0.038 |
    /// | label-ink flips across the table | 13/19 | 0/19 |
    /// | entries under 3:1 vs any of the four canvases | 17/20 | 0/20 |
    /// | worst label contrast | 5.02:1 | 4.60:1 |
    ///
    /// One table serves both appearances, and one label ink serves the whole
    /// table, because four requirements intersect in a single luminance band:
    /// 3:1 against `#F4F5F5` needs Y <= 0.270, 3:1 against `#292929` needs
    /// Y >= 0.167, 4.5:1 for a **black** label needs Y >= 0.175, and the other
    /// two canvases are looser than those. Every fill in both tables sits in
    /// Y ∈ [0.180, 0.265]. A white label would need Y <= 0.183 instead -- a
    /// nearly disjoint band -- so mixing the two inks is precisely what made
    /// the 2026-08-19 table's ink flip on 13 of 19 steps. Choosing one band
    /// removes the flip as a consequence, not as a tweak.
    ///
    /// That band is also the cost, and it is worth naming: 28 fills packed
    /// into one narrow luminance slice have only hue and chroma left to
    /// separate them. Free packing in the same band tops out near ΔE 6.6 for
    /// 28 colours; 5.4 is what remains after Tier A has to be a family, the
    /// states have to keep their semantics, and slot 5 has to be grey. Nothing
    /// here is close to unambiguous, which is the point of the next paragraph.
    ///
    /// Twenty identity colours cannot be made colour-blind-distinct at any
    /// chroma. Measured deuteranope minima over all 190 pairs: this table
    /// 0.97, the 2026-08-19 ring 0.42, upstream's 0.33 -- so this is a 2-3x
    /// improvement on a scale where nothing usable begins until ~15, not a
    /// fix. That is why AT-APP-011 requires colour never to be the only
    /// channel, and why the answer for identity precision is the label, the
    /// Inspector and search, not more saturation.
    ///
    /// `scripts/verify_palette.py` re-derives the *current* figures above from
    /// this file and fails CI on drift. It cannot check the 2026-08-19 column
    /// -- that table no longer exists in any source it reads -- so those are
    /// history rather than invariants. `scripts/test_palette_verifier.py`
    /// mutation-tests the gate itself.
    ///
    /// What did *not* change is which slot an identity lands in: the hash, the
    /// digit stripping and the depth-zero rule below are still upstream's, so
    /// two slices that share a colour in SmartPerf Host still share one here.
    /// `TimelinePaletteTests` locks the table and the assignment.
    public static let funcColorLiterals: [String] = [
        "#377ea7", "#a5698f", "#7388cc", "#419a83", "#22858c",
        "#817e76", "#4893c5", "#83739f", "#6e8b62", "#6276b8",
        "#829446", "#4692a1", "#9c7735", "#488268", "#b58255",
        "#957bbc", "#aa6168", "#6985aa", "#ab7fa4", "#af6943",
    ]

    public static let funcColors: [TimelineColor] = funcColorLiterals.compactMap {
        TimelineColor(hex: $0)
    }

    /// The fill for an event with no identity to hash at all -- upstream's
    /// `ColorUtils.GREY_COLOR` slot, ArkTrace's value.
    ///
    /// Deliberately the same neutral as slot 5. Both mean the same thing --
    /// slot 5 is where `hash("0")` sends a CPU slice with neither pid nor tid,
    /// this is where a named row with no name ends up -- and one "nobody knows
    /// whose this is" colour is easier to read than two. Upstream's `#F0F0F0`
    /// measured 1.14:1 against `#FFFFFF`: an event the renderer could not
    /// identify was also an event the reader could not see.
    public static let greyColor = TimelineColor(red: 0x81, green: 0x7E, blue: 0x76)

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

    /// Upstream `Utils.getStateColor`'s chain over the exact raw state string,
    /// with an ArkTrace fallback through the normalized state.
    ///
    /// The chain -- which spellings exist, which of them share a fill, and
    /// which fall through to the catch-all -- is upstream's, verbatim, and
    /// `TimelinePaletteTests` pins it. The values are not; see ``stateColors``.
    ///
    /// The fallback exists because ArkTrace's normalizer also accepts
    /// spellings upstream never sees (`RUNNABLE`, `READY`, `SLEEPING`,
    /// `BLOCKED`, `UNINTERRUPTIBLE`); those are the same states, and dropping
    /// them into upstream's catch-all would paint a sleeping thread the same
    /// color as a genuinely unknown one.
    public static func stateColor(
        raw: String?,
        normalized: TraceThreadState? = nil
    ) -> TimelineColor {
        if let raw, let exact = stateColors[raw] { return exact }
        switch normalized {
        case .running: return stateColors["Running"] ?? unknownStateColor
        case .runnable: return stateColors["R"] ?? unknownStateColor
        case .sleeping: return stateColors["S"] ?? unknownStateColor
        case .blocked: return stateColors["D"] ?? unknownStateColor
        // Upstream has no branch for `T`; it lands in the catch-all, and so
        // does ArkTrace's `stopped`.
        case .stopped, .none: return unknownStateColor
        }
    }

    /// The fill for a state upstream's chain does not name.
    ///
    /// The only entry in either table that is allowed to be loud: an
    /// unrecognised scheduler state is a data problem, and a data problem
    /// should not blend into the wall. OKLCH chroma 0.155 -- the highest
    /// anywhere in either table -- ΔE 16.0 from `S`, so "asleep" and "no idea"
    /// can never be confused, and ΔE 8.6 from its nearest neighbour of any
    /// kind. That second number is the one that matters, and the one the first
    /// cut got wrong at 5.7: checking the alarm only against `S` pins the pair
    /// that was never going to collide, while the alarm actually sits in the
    /// crowded warm arc alongside a dozen identity fills.
    /// `verify_palette.py` now requires >= 7.0 against everything.
    public static let unknownStateColor = TimelineColor(red: 0xD8, green: 0x5D, blue: 0x72)

    /// Thread-state fills: upstream's chain, ArkTrace's colours.
    ///
    /// Keys are the exact strings upstream compares against, in upstream's
    /// grouping, so the *mapping* stays directly checkable against
    /// `Utils.getStateColor`. The values were Material-2 palette entries taken
    /// from upstream until this change, and they were the actual subject of
    /// the complaint that produced the 2026-08-19 palette rework: `R` was
    /// `#a0b84d` (olive) and `I` was `#673ab7` (grey-purple) -- 「橄榄绿与灰紫」
    /// -- and neither was touched then, because the rework only replaced
    /// ``funcColorLiterals``. Half of all rows are thread-state lanes
    /// (`TraceDocumentController` appends one per thread alongside its named
    /// slices), so this table covers as much canvas as the identity palette
    /// and was doing it in a different visual language.
    ///
    /// Two things were wrong beyond the language mismatch, both measured
    /// against the canvas AppKit resolves (`#FFFFFF` / `#1E1E1E`):
    ///
    /// - **The tiers were inverted.** The loud entries were the rare ones and
    ///   the common ones were invisible: `S` (sleeping, the most common state
    ///   in any capture) sat at 1.32:1 against `#FFFFFF`, `R` at 2.22:1,
    ///   `R-B` at 1.72:1, while `I` -- rare -- was at 7.33:1.
    /// - **Nothing cleared 3:1 in both appearances.** `#e0e0e0` is invisible
    ///   on white; `#673ab7` is invisible on near-black.
    ///
    /// The restatement keeps upstream's grouping and gives the ramp a
    /// semantic shape instead of a palette-swatch one. Quiet where the state
    /// is the common, uninteresting one; chromatic where it is the thing being
    /// looked for:
    ///
    /// | state | fill | role |
    /// |---|---|---|
    /// | `S` sleeping | `#898d94` | most common; near-neutral, recedes |
    /// | `I` idle | `#627987` | quieter still, faintly cooler |
    /// | `R` / `R+` runnable | `#7b7849` | wants CPU and is not getting it |
    /// | `R-B` runnable-blocked | `#948c63` | the `R` family, lighter |
    /// | `Running` | `#489252` | the state a reader scans for |
    /// | `D*` io wait | `#bd7211` | warm signal |
    /// | `D-NIO` / `DK-NIO` | `#a47c74` | the muted member of the `D` family |
    /// | catch-all | `#d85d72` | see ``unknownStateColor`` |
    ///
    /// Measured: every entry sits in the same Y band as ``funcColorLiterals``,
    /// so it clears 3:1 against all four canvases and gives its black label
    /// 4.5:1. Minimum ΔE within this table 6.2; minimum ΔE between this table
    /// and ``funcColorLiterals`` **5.4**. The two tables are optimised
    /// together for that reason -- they alternate row by row, so treating them
    /// as separate problems is what let the first cut land a state fill ΔE 4.9
    /// from a slice fill. 5.4 makes a state lane distinguishable from a slice
    /// lane on inspection; it does not make them two visual languages, and
    /// nothing packed into one narrow luminance band could.
    /// `scripts/verify_palette.py` re-checks all of it, including that
    /// upstream's chain still resolves to exactly seven distinct fills --
    /// merging two states would otherwise vanish from every ΔE measurement
    /// instead of failing one.
    private static let stateColors: [String: TimelineColor] = [
        "D-NIO": TimelineColor(red: 0xA4, green: 0x7C, blue: 0x74),
        "DK-NIO": TimelineColor(red: 0xA4, green: 0x7C, blue: 0x74),
        "D-IO": TimelineColor(red: 0xBD, green: 0x72, blue: 0x11),
        "DK-IO": TimelineColor(red: 0xBD, green: 0x72, blue: 0x11),
        "D": TimelineColor(red: 0xBD, green: 0x72, blue: 0x11),
        "DK": TimelineColor(red: 0xBD, green: 0x72, blue: 0x11),
        "R": TimelineColor(red: 0x7B, green: 0x78, blue: 0x49),
        "R+": TimelineColor(red: 0x7B, green: 0x78, blue: 0x49),
        "R-B": TimelineColor(red: 0x94, green: 0x8C, blue: 0x63),
        "I": TimelineColor(red: 0x62, green: 0x79, blue: 0x87),
        "Running": TimelineColor(red: 0x48, green: 0x92, blue: 0x52),
        "S": TimelineColor(red: 0x89, green: 0x8D, blue: 0x94),
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
/// recolouring them, and a process keeps the colour it has at detail level.
/// (Not the colour it has in SmartPerf Host: the values have been ArkTrace's
/// since 2026-08-19 and only the *slot* an identity lands in is shared.) When
/// the source has no per-event identity — counter
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
