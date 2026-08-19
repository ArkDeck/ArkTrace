import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// Parity gate for the upstream palette port.
///
/// Every expectation in this file was produced by running the upstream
/// `ColorUtils.hash` / `hashFunc` / `funcTextColor` implementations from
/// `openharmony/developtools_smartperf_host` at the revision pinned in
/// `ThirdParty/TraceStreamer/source-lock.json`
/// (`447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6`) under Node, then transcribing
/// the output. The names below deliberately include the cases where a textbook
/// 32-bit FNV-1a diverges from upstream's JavaScript `Number` arithmetic, so a
/// "cleanup" of the hash to integer math fails here instead of silently
/// recoloring every trace.
final class TimelinePaletteTests: XCTestCase {
    /// ArkTrace's own twenty fills, in slot order. Upstream's table was
    /// replaced (see `TimelinePalette.funcColorLiterals` for the measurements
    /// that decided it); the slot an identity lands in did not change, which
    /// is what the vectors below still pin.
    private static let palette: [String] = [
        "#2b4fb0", "#e78f01", "#07b9f1", "#9e2414", "#07c3c1",
        "#96225c", "#04b36d", "#7c318f", "#87a303", "#5044ac",
        "#d4a004", "#0288dd", "#c95c03", "#04c0d8", "#9d1f3e",
        "#05c5a4", "#8c2978", "#2a7a02", "#693aa1", "#bcac03",
    ]

    /// `(name, ColorUtils.hash(name, 20), ColorUtils.hashFunc(name, 0, 20))`.
    private static let hashVectors: [(name: String, hash: Int, hashFunc: Int)] = [
        ("", 13, 13),
        ("a", 12, 12),
        ("A", 4, 4),
        ("ab", 4, 4),
        ("ba", 0, 0),
        ("binder transaction", 0, 0),
        ("H:RSMainThread::DoComposition", 16, 16),
        ("ashmem_alloc", 3, 3),
        ("OS_IPC_0_1234", 4, 4),
        ("render_service", 16, 16),
        ("com.example.myapplication", 2, 2),
        ("H:void OHOS::Rosen::RSRenderThread::RenderLoop()", 4, 4),
        ("Choreographer#doFrame", 14, 14),
        ("ipc::0:1:2:3:4:5:6:7:8:9", 0, 10),
        ("0123456789", 9, 13),
        ("9876543210", 4, 13),
        ("thread-42", 6, 17),
        ("thread-43", 5, 17),
        ("渲染线程", 10, 10),
        ("ArkTrace 时间线", 12, 12),
        ("emoji 🚀 slice", 8, 8),
        (String(repeating: "a", count: 64), 2, 2),
        (
            "H:ReceiveVsync dataCount:24bytes now:123456789 expectedEnd:987654321 vsyncId:4242",
            14, 4
        ),
    ]

    func testPaletteMatchesTheShippedTable() {
        XCTAssertEqual(TimelinePalette.funcColorLiterals, Self.palette)
        XCTAssertEqual(TimelinePalette.funcColors.count, Self.palette.count)
        for (index, literal) in Self.palette.enumerated() {
            XCTAssertEqual(
                TimelinePalette.funcColors[index],
                TimelineColor(hex: literal),
                "palette entry \(index) (\(literal)) did not parse to itself"
            )
        }
    }

    func testHashMatchesUpstreamVectors() {
        for vector in Self.hashVectors {
            XCTAssertEqual(
                TimelinePalette.hash(vector.name, modulus: 20),
                vector.hash,
                "hash(\(vector.name))"
            )
            XCTAssertEqual(
                TimelinePalette.hashFunc(vector.name, depth: 0, modulus: 20),
                vector.hashFunc,
                "hashFunc(\(vector.name))"
            )
        }
    }

    /// Digit stripping is the whole point of upstream's separate `hashFunc`:
    /// slice names that differ only in an embedded number share a color.
    func testHashFuncIgnoresEmbeddedDigits() {
        XCTAssertEqual(
            TimelinePalette.color(forSliceName: "thread-42"),
            TimelinePalette.color(forSliceName: "thread-43")
        )
        XCTAssertNotEqual(
            TimelinePalette.color(forName: "thread-42"),
            TimelinePalette.color(forName: "thread-43")
        )
    }

    /// `(name, hashFunc(name, 1, 20), hashFunc(name, 7, 20))`.
    func testHashFuncAppliesDepthOffset() {
        let vectors: [(String, Int, Int)] = [
            ("", 14, 0),
            ("a", 13, 19),
            ("A", 5, 11),
            ("ab", 5, 11),
            ("ba", 1, 7),
            ("binder transaction", 1, 7),
            ("H:RSMainThread::DoComposition", 17, 3),
            ("ashmem_alloc", 4, 10),
        ]
        for (name, depth1, depth7) in vectors {
            XCTAssertEqual(TimelinePalette.hashFunc(name, depth: 1, modulus: 20), depth1)
            XCTAssertEqual(TimelinePalette.hashFunc(name, depth: 7, modulus: 20), depth7)
        }
    }

    /// The depth-layering work (P7-T04) makes real call depth available at the
    /// point where fill colour is chosen, and `hashFunc` accepts a depth — so
    /// passing it through is the obvious-looking change. It would be wrong:
    /// at the pinned upstream revision `ProcedureWorkerFunc` passes a literal
    /// `0`, not `funcNode.depth` (UPSTREAM_ALIGNMENT_AUDIT §5), so a slice must
    /// keep one colour no matter how deep it sits. `hashFunc` above proves the
    /// depth argument *does* change the result, which is exactly why the
    /// renderer must not supply it.
    func testSameSliceNameKeepsOneColourAtEveryDepth() throws {
        let names = [
            "binder transaction",
            "H:RSMainThread::DoComposition",
            "ashmem_alloc",
            "H:OnVsyncEvent",
        ]
        for name in names {
            let expected = TimelinePalette.color(forSliceName: name)
            XCTAssertEqual(
                TimelinePalette.color(forSliceName: name, depth: 0), expected,
                "\(name) must use the depth-0 colour"
            )
            // Every primitive the renderer can produce, across depths.
            for depth in 0...20 {
                let primitive = TimelineDetailPrimitive(
                    trackID: TimelineTrackID(rawValue: "named-slice:1"),
                    eventKey: EventKey(table: .callstack, rowID: Int64(depth) + 1),
                    range: try TraceTimeRange(startNs: 0, endNs: 10),
                    label: name,
                    category: "slice",
                    depth: depth
                )
                XCTAssertEqual(
                    TimelineDetailPalette.color(for: primitive), expected,
                    "\(name) changed colour at depth \(depth)"
                )
            }
        }
    }

    /// `ColorUtils.colorForTid` over the decimal identity.
    ///
    /// Pinned as **slots**, not as colours: the slot is the upstream-parity
    /// fact -- two identities that share a colour in SmartPerf Host share one
    /// here -- while which colour sits in that slot is ArkTrace's own choice
    /// and is locked separately by `testPaletteMatchesTheShippedTable`.
    func testProcessIdentitySlotsMatchUpstream() {
        let vectors: [(Int64, Int)] = [
            (0, 5),
            (1, 4),
            (2, 7),
            (7, 2),
            (42, 4),
            (100, 16),
            (999, 12),
            (1234, 0),
            (32768, 12),
            (65535, 8),
            (2_147_483_647, 12),
        ]
        for (identity, slot) in vectors {
            XCTAssertEqual(
                TimelinePalette.color(forProcessOrThreadID: identity),
                TimelinePalette.funcColors[slot],
                "colorForTid(\(identity)) should land in slot \(slot)"
            )
        }
    }

    /// `ColorUtils.funcTextColor` over the palette. Nine of the twenty are dark
    /// enough for a white label -- under upstream's table it was one -- which
    /// is exactly why the renderer cannot hardcode either colour.
    func testLabelColorMatchesUpstreamLuminanceRule() {
        let takesWhiteLabel: Set<Int> = [0, 3, 5, 7, 9, 14, 16, 17, 18]
        for (index, literal) in Self.palette.enumerated() {
            let expected: TimelineColor = takesWhiteLabel.contains(index) ? .white : .black
            XCTAssertEqual(
                TimelineColor(hex: literal)?.preferredLabelColor,
                expected,
                "funcTextColor(\(literal)) at index \(index)"
            )
        }
        XCTAssertEqual(TimelineColor(hex: "#000000")?.preferredLabelColor, .white)
        XCTAssertEqual(TimelineColor(hex: "#ffffff")?.preferredLabelColor, .black)
    }

    func testStateColorsMatchUpstreamChain() {
        let vectors: [(String, String)] = [
            ("D-NIO", "#795548"),
            ("DK-NIO", "#795548"),
            ("D-IO", "#f19b38"),
            ("DK-IO", "#f19b38"),
            ("D", "#f19b38"),
            ("DK", "#f19b38"),
            ("R", "#a0b84d"),
            ("R+", "#a0b84d"),
            ("R-B", "#87CEFA"),
            ("I", "#673ab7"),
            ("Running", "#467b3b"),
            ("S", "#e0e0e0"),
            // Upstream's catch-all.
            ("T", "#ff6e40"),
            ("X", "#ff6e40"),
            ("", "#ff6e40"),
            ("unknown-state", "#ff6e40"),
        ]
        for (state, hex) in vectors {
            XCTAssertEqual(
                TimelinePalette.stateColor(raw: state),
                TimelineColor(hex: hex),
                "getStateColor(\(state))"
            )
        }
    }

    /// ArkTrace accepts state spellings upstream never emits. Those must reach
    /// the same color as their upstream-spelled equivalent rather than the
    /// catch-all, or a sleeping thread would be indistinguishable from one in
    /// an unrecognized state.
    func testNormalizedStateFallbackAvoidsUpstreamCatchAll() {
        let equivalents: [(raw: String, normalized: TraceThreadState, upstream: String)] = [
            ("RUNNABLE", .runnable, "R"),
            ("READY", .runnable, "R"),
            ("SLEEPING", .sleeping, "S"),
            ("SLEEP", .sleeping, "S"),
            ("BLOCKED", .blocked, "D"),
            ("UNINTERRUPTIBLE", .blocked, "D"),
        ]
        for case let (raw, normalized, upstream) in equivalents {
            XCTAssertEqual(
                TimelinePalette.stateColor(raw: raw, normalized: normalized),
                TimelinePalette.stateColor(raw: upstream),
                "\(raw) should match upstream's \(upstream)"
            )
        }
        // `stopped` has no upstream branch, so it keeps the catch-all.
        XCTAssertEqual(
            TimelinePalette.stateColor(raw: "STOPPED", normalized: .stopped),
            TimelinePalette.unknownStateColor
        )
        // An exact upstream spelling always wins over the normalized fallback.
        XCTAssertEqual(
            TimelinePalette.stateColor(raw: "R-B", normalized: .runnable),
            TimelineColor(hex: "#87CEFA")
        )
    }

    func testHexParsingRejectsMalformedLiterals() {
        XCTAssertNil(TimelineColor(hex: "23b0e7"))
        XCTAssertNil(TimelineColor(hex: "#23b0e"))
        XCTAssertNil(TimelineColor(hex: "#zzzzzz"))
        XCTAssertNil(TimelineColor(hex: "#"))
        // Upstream's three-digit shorthand expands each nibble.
        XCTAssertEqual(TimelineColor(hex: "#f0f"), TimelineColor(hex: "#ff00ff"))
    }

    func testModulusGuardIsTotal() {
        XCTAssertEqual(TimelinePalette.hash("anything", modulus: 0), 0)
        XCTAssertEqual(TimelinePalette.hash("anything", modulus: -3), 0)
        XCTAssertEqual(TimelinePalette.hashFunc("anything", depth: 2, modulus: 0), 0)
    }

    // MARK: - Primitive resolution

    func testCpuSliceTakesProcessIdentity() throws {
        let detail = try Self.detail(
            category: "cpu",
            label: "TID 99",
            type: .cpuSlice,
            pid: 1234,
            tid: 99
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: detail),
            TimelinePalette.color(forProcessOrThreadID: 1234),
            "a CPU slice is colored by the process that was running"
        )
    }

    func testCpuSliceWithoutProcessFallsBackToThreadIdentity() throws {
        let detail = try Self.detail(
            category: "cpu", label: "TID 99", type: .cpuSlice, pid: nil, tid: 99
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: detail),
            TimelinePalette.color(forProcessOrThreadID: 99)
        )
        let anonymous = try Self.detail(
            category: "cpu", label: nil, type: .cpuSlice, pid: nil, tid: nil
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: anonymous),
            TimelinePalette.color(forProcessOrThreadID: 0),
            "upstream hashes `tid || 0` rather than falling out of the palette"
        )
    }

    func testThreadStateTakesRawStateColor() throws {
        let detail = try Self.detail(
            category: "sleeping", label: "S", type: .threadState, state: "S"
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: detail),
            TimelinePalette.stateColor(raw: "S")
        )
    }

    func testNamedSliceTakesDigitStrippedNameColor() throws {
        let detail = try Self.detail(
            category: "binder", label: "binder transaction", type: .namedSlice,
            name: "binder transaction"
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: detail),
            TimelinePalette.color(forSliceName: "binder transaction")
        )
    }

    func testCounterSeriesTakesItsOwnNameColor() throws {
        let cpuFrequency = try Self.detail(
            category: "counter", label: "cpufreq", type: .counter, name: "cpufreq"
        )
        let memory = try Self.detail(
            category: "counter", label: "mem.rss", type: .counter, name: "mem.rss"
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: cpuFrequency),
            TimelinePalette.color(forSliceName: "cpufreq")
        )
        XCTAssertNotEqual(
            TimelineDetailPalette.color(for: cpuFrequency),
            TimelineDetailPalette.color(for: memory),
            "two counter series should be separable by color"
        )
    }

    /// Snapshots built without an inspector still have to resolve — the
    /// renderer must never fall back to a single flat fill.
    func testInspectorlessPrimitivesResolveFromCategory() throws {
        XCTAssertEqual(
            TimelineDetailPalette.color(for: try Self.detail(category: "cpu", label: "TID 7")),
            TimelinePalette.color(forProcessOrThreadID: 0)
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: try Self.detail(category: "running", label: "Running")),
            TimelinePalette.stateColor(raw: "Running")
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: try Self.detail(category: "other", label: "work")),
            TimelinePalette.color(forSliceName: "work")
        )
        XCTAssertEqual(
            TimelineDetailPalette.color(for: try Self.detail(category: nil, label: nil)),
            TimelinePalette.greyColor,
            "an event with no identity at all takes upstream's grey"
        )
    }

    private static func detail(
        category: String?,
        label: String?,
        type: TraceInspectorEventType? = nil,
        name: String? = nil,
        pid: Int64? = nil,
        tid: Int64? = nil,
        state: String? = nil
    ) throws -> TimelineDetailPrimitive {
        let range = try TraceTimeRange(startNs: 0, endNs: 1_000)
        let key = EventKey(table: .callstack, rowID: 1)
        return TimelineDetailPrimitive(
            trackID: TimelineTrackID(rawValue: "test"),
            eventKey: key,
            range: range,
            label: label,
            category: category,
            inspector: type.map { type in
                TraceEventInspector(
                    key: key,
                    type: type,
                    name: name,
                    range: range,
                    semanticDurationNs: 1_000,
                    isOpenEnded: false,
                    processKey: nil,
                    threadKey: nil,
                    pid: pid,
                    tid: tid,
                    cpu: nil,
                    processName: nil,
                    threadName: nil,
                    category: category,
                    state: state,
                    value: nil,
                    unit: nil
                )
            }
        )
    }
}
