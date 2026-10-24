import ArkTraceCore
import ArkTraceRendering
import SwiftUI

/// The open in progress, when there is no timeline yet to put it beside.
///
/// Opening a real capture is seconds to a minute of parsing, indexing and
/// validating, and the corner pill this replaces said `Opening database…` in
/// the top-left of an otherwise blank pane: no file, no sense of where in the
/// pipeline the work was, and nothing to tell a slow stage from a stuck one.
///
/// Everything here is a stock control (SPECIFICATION §17 asks for native ones)
/// and nothing animates on its own except `ProgressView`, whose motion AppKit
/// already ties to Reduce Motion. State is carried by shape and text, never by
/// colour alone (AT-APP-011).
///
/// There is deliberately no row of pipeline dots under the status line. It was
/// here and it was removed: a cache hit goes preparing, hashing, cacheLookup,
/// openingDatabase and never parses, validates or indexes at all, so the row
/// lit three steps that had not happened; by the last stage -- which is the
/// screen a slow open sits on longest -- every dot was lit and the row said
/// nothing; and seven equal dots implied seven equal steps when parsing and
/// indexing take fifteen times what hashing does. A step counter would inherit
/// the same lie in its denominator, so nothing replaced it. What is left is
/// what the open can actually measure.
struct TraceLoadingPane: View {
    let stage: TraceLoadingStage
    /// 0…1 within the stage, when the stage can say. Nil is not zero: it means
    /// this step has no measure of its own extent.
    let fraction: Double?
    let fileName: String?
    let cancel: @MainActor () -> Void
    let openPanel: @MainActor () -> Void

    /// A cache hit reaches Ready in well under a second. Showing a full pane
    /// for that is a flash of furniture, so the pane waits before appearing --
    /// long enough that a fast open never draws it, short enough that a slow
    /// one still feels answered.
    private static let appearanceDelay = Duration.milliseconds(220)
    /// Elapsed time only earns its place once the wait is long enough to
    /// wonder about; before that it is a counter ticking 0, 1 for no reason.
    private static let elapsedThresholdSeconds = 2

    @State private var isVisible = false
    @State private var elapsedSeconds = 0

    var body: some View {
        // `cancelled` is a loading stage the way `failed` is: the phase
        // stays `.loading` until something else is opened. Spinning at the
        // user after they pressed Cancel is worse than saying so and
        // offering the one thing there is left to do.
        if stage == .cancelled {
            ContentUnavailableView {
                Label("Opening cancelled", systemImage: "xmark.circle")
            } description: {
                Text(fileName ?? "")
            } actions: {
                Button("Open Trace…", action: openPanel)
                    .buttonStyle(.borderedProminent)
                    .arktraceAccessibleTarget()
            }
        } else {
            progress
        }
    }

    private var progress: some View {
        VStack(spacing: 18) {
            // One bar, determinate when the stage reports a fraction and
            // indeterminate when it cannot, rather than a spinner that becomes
            // a bar: the geometry stays put as the open moves between stages
            // that can measure themselves and stages that cannot.
            ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .frame(width: 260)
            VStack(spacing: 5) {
                if let fileName {
                    Text(fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .arktraceAccessibleTarget()
        }
        .padding(30)
        .frame(maxWidth: 460)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .task {
            try? await Task.sleep(for: Self.appearanceDelay)
            isVisible = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                elapsedSeconds += 1
            }
        }
    }

    /// The cache lookup is two different jobs: consulting metadata on a hit,
    /// and copying the source into an immutable snapshot on a miss. Only the
    /// second has bytes to count, so a fraction here is the tell.
    private var stageText: String {
        stage == .cacheLookup && fraction != nil ? "Copying trace…" : stageLabel(stage)
    }

    private var statusText: String {
        var parts = [stageText]
        if let fraction { parts.append("\(Int(fraction * 100))%") }
        if elapsedSeconds >= Self.elapsedThresholdSeconds {
            parts.append(Self.elapsedText(elapsedSeconds))
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Composed rather than formatted. The C-variadic `String` formatter is
    /// both a strict-memory-safety warning and something `LocalizationCatalog
    /// Tests` forbids the app outright, and a two-field clock needs no
    /// formatter anyway.
    static func elapsedText(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds)s" }
        let remainder = seconds % 60
        return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
    }
}
