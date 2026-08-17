import AppKit
import ArkTraceCore
import SwiftUI

@MainActor
public final class TimelineNSView: NSView {
    public var snapshot: TimelineSnapshot? {
        didSet {
            let previousRenderedIdentity = Self.renderIdentity(
                current: oldValue, previous: previousSnapshot
            )
            if snapshot == nil {
                previousSnapshot = nil
            } else if let oldValue, snapshot?.generation != oldValue.generation,
                snapshot?.isLoading == true
            {
                previousSnapshot = oldValue
            } else if let snapshot, !snapshot.isLoading {
                previousSnapshot = snapshot
            }
            if previousRenderedIdentity != Self.renderIdentity(
                current: snapshot, previous: previousSnapshot
            ) {
                densityPathCache = nil
                detailPathCache = nil
            }
            needsDisplay = true
        }
    }
    public var selection: TraceTimeRange? {
        didSet {
            guard selection != oldValue else { return }
            needsDisplay = true
            if dragStartX == nil, !suppressAccessibilityNotifications {
                postAccessibilityValueChanged()
            }
        }
    }
    public var selectedEventKey: EventKey? {
        didSet {
            guard selectedEventKey != oldValue else { return }
            if let selectedEventKey {
                focus(eventKey: selectedEventKey, notifyAccessibility: false)
            }
            needsDisplay = true
            if !suppressAccessibilityNotifications { postAccessibilityValueChanged() }
        }
    }
    public var onSelectEvent: (@MainActor (EventKey?) -> Void)?
    public var onHoverEvent: (@MainActor (EventKey?) -> Void)?
    public var onSelectRange: (@MainActor (TraceTimeRange?) -> Void)?
    public var onViewportIntent: (@MainActor (TimelineViewportIntent) -> Void)?
    public var onZoomSelection: (@MainActor () -> Void)?
    public var onResetViewport: (@MainActor () -> Void)?
    /// Trace-relative bounds used to suppress accessibility actions whose
    /// clamped result would equal the current viewport.
    public var interactionBounds: TraceTimeRange?

    public private(set) var focusedEventKey: EventKey?
    public private(set) var focusedTrackID: TimelineTrackID?

    private var previousSnapshot: TimelineSnapshot?
    private var dragStartX: CGFloat?
    private var dragInitialSelection: TraceTimeRange?
    private var suppressAccessibilityNotifications = false
    private var trackingAreaReference: NSTrackingArea?
    /// Last known pointer position in view coordinates, or nil while the
    /// pointer is outside. It is the zoom anchor for `W`/`S`, matching
    /// upstream's `centerXPercentage`.
    private var pointerLocation: CGPoint?

    /// One batched density fill: the owning track's palette color plus the
    /// existing eight-step intensity ramp.
    private struct DensityPaintKey: Hashable, Comparable {
        let color: TimelineColor
        let intensity: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.intensity, lhs.color) < (rhs.intensity, rhs.color)
        }
    }

    private struct DensityPaths {
        let backingScale: CGFloat
        let paths: [DensityPaintKey: CGPath]
    }

    /// One batched detail fill. The semantic style stays the outer sort key so
    /// the paint order — and with it the hit-test priority in ``event(at:)`` —
    /// is exactly what it was before events gained individual colors.
    private struct DetailPaintKey: Hashable, Comparable {
        let style: DetailVisualStyle
        let color: TimelineColor

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.style.rawValue, lhs.color) < (rhs.style.rawValue, rhs.color)
        }
    }

    private struct DetailLabel {
        let value: String
        let frame: CGRect
        /// Resolved from the fill's luminance, because most of the palette is
        /// too light to carry a white label.
        let color: TimelineColor
    }

    private struct DetailPaths {
        let backingScale: CGFloat
        let paths: [DetailPaintKey: CGPath]
        let labels: [DetailLabel]
        let events: [EventKey: (TimelineDetailPrimitive, CGRect)]
    }

    private var densityPathCache: DensityPaths?
    private var detailPathCache: DetailPaths?
    var accessibilityValueChangedHook: (() -> Void)?
    var pathCacheBuildHook: ((_ kind: String, _ bucketCount: Int) -> Void)?

    private enum DetailVisualStyle: Int, CaseIterable {
        case running
        case runnable
        case blocked
        case sleeping
        case counter
        case accent
    }

    private struct RenderIdentity: Equatable {
        let generation: UInt64
        let isLoading: Bool
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var focusRingMaskBounds: NSRect { bounds }

    public override func drawFocusRingMask() {
        bounds.fill()
    }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        unsafe NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }

    public override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        densityPathCache = nil
        detailPathCache = nil
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)
        guard let source = displayedSnapshot else { return }
        drawRuler(source, context: context)
        drawTracks(source, dirtyRect: dirtyRect, context: context)
        drawSelection(source, context: context)
        if snapshot?.isLoading == true {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor)
            context.fill(bounds)
        }
    }

    public func event(at point: CGPoint) -> EventKey? {
        guard let source = displayedSnapshot else { return nil }
        let scale = unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var candidate: (style: Int, order: Int, key: EventKey)?
        var order = 0
        for track in source.tracks {
            for primitive in track.primitives {
                defer { order += 1 }
                guard TimelineGeometry.trackFrame(track).contains(point),
                    case .detail(let detail) = primitive
                else { continue }
                let frame = TimelineGeometry.frame(
                    for: primitive, in: track,
                    viewport: source.viewport, backingScale: scale
                )
                guard frame.insetBy(dx: -1, dy: -1).contains(point) else { continue }
                let hit = (Self.visualStyle(for: detail.category).rawValue, order, detail.eventKey)
                if candidate == nil || hit.0 > candidate!.style
                    || (hit.0 == candidate!.style && hit.1 > candidate!.order)
                {
                    candidate = hit
                }
            }
        }
        return candidate?.key
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let selected = self.event(at: point) {
            dragStartX = nil
            dragInitialSelection = nil
            onSelectRange?(nil)
            onSelectEvent?(selected)
        } else {
            onSelectEvent?(nil)
            dragStartX = point.x
            dragInitialSelection = selection
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let startX = dragStartX, let source = displayedSnapshot else { return }
        let endX = convert(event.locationInWindow, from: nil).x
        let first = TimelineGeometry.time(forX: startX, viewport: source.viewport)
        let second = TimelineGeometry.time(forX: endX, viewport: source.viewport)
        guard first != second else {
            selection = nil
            onSelectRange?(nil)
            return
        }
        let range = try? TraceTimeRange.query(
            startNs: min(first, second),
            endNs: max(first, second)
        )
        selection = range
        onSelectRange?(range)
    }

    public override func mouseUp(with event: NSEvent) {
        if dragStartX != nil { mouseDragged(with: event) }
        if dragStartX != nil { commitRangeSelectionAccessibilityChange(from: dragInitialSelection) }
        dragStartX = nil
        dragInitialSelection = nil
    }

    /// Range drags update the visible selection synchronously, but expose only
    /// the final semantic value to assistive technology.
    func commitRangeSelectionAccessibilityChange(from previous: TraceTimeRange?) {
        if selection != previous { postAccessibilityValueChanged() }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updatePointerLocation(point)
        onHoverEvent?(self.event(at: point))
    }

    public override func mouseExited(with event: NSEvent) {
        updatePointerLocation(nil)
    }

    /// Records the pointer position that anchors `W` / `S`. Also the seam tests
    /// use to place the pointer without synthesizing an `NSEvent`.
    package func updatePointerLocation(_ point: CGPoint?) {
        pointerLocation = point
    }

    public override func magnify(with event: NSEvent) {
        guard let source = displayedSnapshot else { return }
        let point = convert(event.locationInWindow, from: nil)
        let anchor = TimelineGeometry.time(forX: point.x, viewport: source.viewport)
        onViewportIntent?(
            .zoom(
                anchorNs: anchor,
                scale: exp(-Double(event.magnification)),
                sourceViewport: source.viewport
            )
        )
    }

    public override func scrollWheel(with event: NSEvent) {
        let horizontal = Double(event.scrollingDeltaX)
        guard abs(horizontal) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        guard let source = displayedSnapshot else { return }
        onViewportIntent?(.panPoints(horizontal, sourceViewport: source.viewport))
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = modifiers.contains(.option)
        switch event.keyCode {
        case 123:
            performKeyboardCommand(option ? .panBackward : .previousEvent)
        case 124:
            performKeyboardCommand(option ? .panForward : .nextEvent)
        case 125:
            performKeyboardCommand(.nextTrack)
        case 126:
            performKeyboardCommand(.previousTrack)
        default:
            // A Command-modified key belongs to the menu, not to the timeline.
            // Letting `W` swallow ⌘W would break Close Window.
            guard !modifiers.contains(.command) else {
                super.keyDown(with: event)
                return
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "+", "=": performKeyboardCommand(.zoomIn)
            case "-", "_": performKeyboardCommand(.zoomOut)
            case "\r", "\n": performKeyboardCommand(.selectFocusedEvent)
            // SmartPerf Host's navigation cluster: W/S zoom about the pointer,
            // A/D pan, and `[` / `]` are upstream aliases for its zoom-to-
            // selection key, which ArkTrace already binds to F.
            case "w": performKeyboardCommand(.zoomInAtPointer)
            case "s": performKeyboardCommand(.zoomOutAtPointer)
            case "a": performKeyboardCommand(.panBackward)
            case "d": performKeyboardCommand(.panForward)
            case "f", "[", "]": performKeyboardCommand(.zoomSelection)
            case "0": performKeyboardCommand(.resetViewport)
            case "\u{1b}": performKeyboardCommand(.clearSelection)
            default:
                super.keyDown(with: event)
            }
        }
    }

    /// Testable keyboard/accessibility command boundary. Every command is
    /// synchronous and only considers primitives already in the bounded
    /// immutable snapshot.
    @discardableResult
    package func performKeyboardCommand(_ command: TimelineKeyboardCommand) -> Bool {
        switch command {
        case .previousEvent:
            return moveEvent(by: -1)
        case .nextEvent:
            return moveEvent(by: 1)
        case .previousTrack:
            return moveTrack(by: -1)
        case .nextTrack:
            return moveTrack(by: 1)
        case .panBackward, .panForward,
            .zoomIn, .zoomOut,
            .zoomInAtPointer, .zoomOutAtPointer:
            guard let intent = viewportIntent(for: command), let onViewportIntent
            else { return false }
            onViewportIntent(intent)
            return true
        case .selectFocusedEvent:
            let previousFocusedEvent = focusedEventKey
            let previousFocusedTrack = focusedTrackID
            let previousSelectedEvent = selectedEventKey
            let previousSelection = selection
            suppressAccessibilityNotifications = true
            if focusedEventKey == nil { _ = moveEvent(by: 1) }
            guard let focusedEventKey else {
                suppressAccessibilityNotifications = false
                return false
            }
            selection = nil
            selectedEventKey = focusedEventKey
            suppressAccessibilityNotifications = false
            onSelectRange?(nil)
            onSelectEvent?(focusedEventKey)
            let changed = previousFocusedEvent != self.focusedEventKey
                || previousFocusedTrack != focusedTrackID
                || previousSelectedEvent != selectedEventKey
                || previousSelection != selection
            if changed { postAccessibilityValueChanged() }
            return changed
        case .zoomSelection:
            guard let source = displayedSnapshot, let selection,
                selection != source.viewport.range, let onZoomSelection
            else { return false }
            onZoomSelection()
            return true
        case .resetViewport:
            guard let source = displayedSnapshot, let interactionBounds,
                source.viewport.range != interactionBounds, let onResetViewport
            else { return false }
            onResetViewport()
            return true
        case .clearSelection:
            let semanticValueChanged = selectedEventKey != nil || focusedEventKey != nil
                || focusedTrackID != nil || selection != nil
            guard semanticValueChanged else { return false }
            suppressAccessibilityNotifications = true
            selectedEventKey = nil
            focusedEventKey = nil
            focusedTrackID = nil
            selection = nil
            suppressAccessibilityNotifications = false
            onSelectEvent?(nil)
            onSelectRange?(nil)
            postAccessibilityValueChanged()
            return true
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    private var displayedSnapshot: TimelineSnapshot? {
        if snapshot?.isLoading == true { return previousSnapshot ?? snapshot }
        return snapshot ?? previousSnapshot
    }

    private func drawRuler(_ snapshot: TimelineSnapshot, context: CGContext) {
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: TimelineGeometry.rulerHeight))
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        unsafe context.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
        context.move(to: CGPoint(x: 0, y: TimelineGeometry.rulerHeight))
        context.addLine(to: CGPoint(x: bounds.width, y: TimelineGeometry.rulerHeight))
        context.strokePath()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for index in 0...4 {
            let x = bounds.width * CGFloat(index) / 4
            let time = TimelineGeometry.time(forX: x, viewport: snapshot.viewport)
            let label = Self.timeLabel(time)
            label.draw(at: CGPoint(x: min(x + 2, max(0, bounds.width - 80)), y: 4), withAttributes: attributes)
        }
    }

    private func drawTracks(
        _ snapshot: TimelineSnapshot,
        dirtyRect: CGRect,
        context: CGContext
    ) {
        let scale = unsafe window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for (index, track) in snapshot.tracks.enumerated() {
            let trackFrame = TimelineGeometry.trackFrame(track)
            guard trackFrame.maxY >= dirtyRect.minY, trackFrame.minY <= dirtyRect.maxY else { continue }
            context.setFillColor(
                (index.isMultiple(of: 2)
                    ? NSColor.textBackgroundColor
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.45)).cgColor
            )
            context.fill(CGRect(x: 0, y: trackFrame.minY, width: bounds.width, height: trackFrame.height))
        }
        drawDensityOverlay(snapshot, backingScale: scale, context: context)
        drawDetailOverlay(snapshot, backingScale: scale, context: context)
        for track in snapshot.tracks {
            let trackFrame = TimelineGeometry.trackFrame(track)
            guard trackFrame.maxY >= dirtyRect.minY, trackFrame.minY <= dirtyRect.maxY else { continue }
            context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1 / scale)
            context.move(to: CGPoint(x: 0, y: trackFrame.maxY))
            context.addLine(to: CGPoint(x: bounds.width, y: trackFrame.maxY))
            context.strokePath()
        }
    }

    /// Density primitives are non-selectable and carry only intensity, so they
    /// are merged into snapshot-wide alpha paths: hover, focus and selection
    /// redraws perform a handful of fills instead of up to eight per track,
    /// while retaining vector-sharp bucket boundaries.
    ///
    /// An aggregate bucket has no single event to take a color from, so the
    /// band takes the owning track's identity color and keeps the intensity in
    /// the alpha ramp. That is ArkTrace's own encoding rather than an upstream
    /// one — upstream has no density level of detail — and it exists so an
    /// overview of many tracks is still readable as separate tracks. The batch
    /// count is therefore bounded by visible tracks × 8 rather than by 8, which
    /// is still a small constant against the per-primitive fills this avoids.
    private func drawDensityOverlay(
        _ snapshot: TimelineSnapshot,
        backingScale: CGFloat,
        context: CGContext
    ) {
        let cached: DensityPaths
        if let densityPathCache, densityPathCache.backingScale == backingScale {
            cached = densityPathCache
        } else {
            var paths: [DensityPaintKey: CGMutablePath] = [:]
            let minimumWidth = 1 / max(1, backingScale)
            for track in snapshot.tracks where !track.primitives.isEmpty {
                let color = Self.trackColor(for: track.descriptor)
                for primitive in track.primitives {
                    guard case .density(let density) = primitive else { continue }
                    let intensity = min(7, Int(log2(Double(max(1, density.bucket.eventCount)))))
                    let key = DensityPaintKey(color: color, intensity: intensity)
                    let path = paths[key] ?? CGMutablePath()
                    let startX = TimelineGeometry.x(
                        for: density.bucket.range.startNs, viewport: snapshot.viewport
                    )
                    let endX = TimelineGeometry.x(
                        for: density.bucket.range.endNs, viewport: snapshot.viewport
                    )
                    path.addRect(
                        CGRect(
                            x: startX,
                            y: TimelineGeometry.rulerHeight + CGFloat(track.y) + 3,
                            width: max(minimumWidth, endX - startX),
                            height: max(1, CGFloat(track.height) - 6)
                        )
                    )
                    paths[key] = path
                }
            }
            cached = DensityPaths(backingScale: backingScale, paths: paths)
            densityPathCache = cached
            pathCacheBuildHook?("density", paths.count)
        }
        for key in cached.paths.keys.sorted() {
            guard let path = cached.paths[key] else { continue }
            let alpha = min(0.9, 0.18 + Double(key.intensity) * 0.1)
            context.setFillColor(key.color.cgColor(alpha: alpha))
            context.addPath(path)
            context.fillPath()
        }
    }

    /// Detail event geometry is immutable within a snapshot. Batch its static
    /// color fills, retain the real event/frame mapping for hit testing and
    /// focus outlines, and draw labels only for the few sufficiently wide
    /// events. This keeps 20k-detail snapshots from issuing one CoreGraphics
    /// fill call per event on every hover redraw.
    ///
    /// Batching survives per-event colors because the palette is closed: an
    /// event's fill comes from a fixed twenty-entry table or the fixed thread
    /// state table, so the number of distinct fills is bounded by the palette
    /// and not by the number of events. The semantic style stays the outer
    /// batch key so the paint order is unchanged.
    private func drawDetailOverlay(
        _ snapshot: TimelineSnapshot,
        backingScale: CGFloat,
        context: CGContext
    ) {
        let cached: DetailPaths
        if let detailPathCache, detailPathCache.backingScale == backingScale {
            cached = detailPathCache
        } else {
            var mutablePaths: [DetailPaintKey: CGMutablePath] = [:]
            var labels: [DetailLabel] = []
            var events: [EventKey: (TimelineDetailPrimitive, CGRect)] = [:]
            for track in snapshot.tracks {
                for primitive in track.primitives {
                    guard case .detail(let detail) = primitive else { continue }
                    let frame = TimelineGeometry.frame(
                        for: primitive,
                        in: track,
                        viewport: snapshot.viewport,
                        backingScale: backingScale
                    )
                    let color = TimelineDetailPalette.color(for: detail)
                    let key = DetailPaintKey(
                        style: Self.visualStyle(for: detail.category), color: color
                    )
                    let path = mutablePaths[key] ?? CGMutablePath()
                    path.addRect(frame)
                    mutablePaths[key] = path
                    events[detail.eventKey] = (detail, frame)
                    if let label = detail.label,
                        frame.width >= TimelineGeometry.minimumLabelWidth
                    {
                        labels.append(
                            DetailLabel(
                                value: label,
                                frame: frame,
                                color: color.preferredLabelColor
                            )
                        )
                    }
                }
            }
            cached = DetailPaths(
                backingScale: backingScale,
                paths: mutablePaths,
                labels: labels,
                events: events
            )
            detailPathCache = cached
            pathCacheBuildHook?("detail", mutablePaths.count)
        }
        for key in cached.paths.keys.sorted() {
            guard let path = cached.paths[key] else { continue }
            context.setFillColor(key.color.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        let labelFont = NSFont.systemFont(ofSize: 9)
        for label in cached.labels {
            context.saveGState()
            context.clip(to: label.frame.insetBy(dx: 1, dy: 1))
            label.value.draw(
                at: CGPoint(
                    x: label.frame.minX + TimelineGeometry.horizontalLabelInset,
                    y: label.frame.minY + max(1, (label.frame.height - 11) / 2)
                ),
                withAttributes: [
                    .font: labelFont,
                    .foregroundColor: NSColor(cgColor: label.color.cgColor) ?? .labelColor,
                ]
            )
            context.restoreGState()
        }
        var outlined = Set<EventKey>()
        for key in [selectedEventKey, focusedEventKey].compactMap({ $0 }) {
            guard outlined.insert(key).inserted,
                let (detail, frame) = cached.events[key]
            else { continue }
            drawEventState(detail, frame: frame, context: context)
        }
    }

    private func drawSelection(_ snapshot: TimelineSnapshot, context: CGContext) {
        guard let selection, selection.startNs <= snapshot.viewport.range.endNs,
            selection.endNs >= snapshot.viewport.range.startNs
        else { return }
        let start = TimelineGeometry.x(for: selection.startNs, viewport: snapshot.viewport)
        let end = TimelineGeometry.x(for: selection.endNs, viewport: snapshot.viewport)
        context.setFillColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).cgColor)
        context.fill(
            CGRect(
                x: start, y: TimelineGeometry.rulerHeight,
                width: max(1, end - start),
                height: max(0, bounds.height - TimelineGeometry.rulerHeight)
            )
        )
        context.saveGState()
        context.setStrokeColor(NSColor.selectedControlColor.cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(
            CGRect(
                x: start + 1, y: TimelineGeometry.rulerHeight + 1,
                width: max(0, max(1, end - start) - 2),
                height: max(0, bounds.height - TimelineGeometry.rulerHeight - 2)
            )
        )
        context.restoreGState()
    }

    private func drawEventState(
        _ detail: TimelineDetailPrimitive,
        frame: CGRect,
        context: CGContext
    ) {
        let isSelected = detail.eventKey == selectedEventKey
        let isFocused = detail.eventKey == focusedEventKey
        guard isSelected || isFocused else { return }
        context.saveGState()
        context.setFillColor(NSColor.clear.cgColor)
        context.setStrokeColor(
            (isSelected ? NSColor.selectedControlTextColor : NSColor.keyboardFocusIndicatorColor)
                .cgColor
        )
        context.setLineWidth(isSelected ? 3 : 2)
        if isFocused && !isSelected {
            context.setLineDash(phase: 0, lengths: [3, 2])
        }
        context.stroke(frame.insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    private struct FocusLocation {
        let trackIndex: Int
        let detail: TimelineDetailPrimitive
    }

    private func focusLocations(in trackIndex: Int) -> [FocusLocation] {
        guard let source = displayedSnapshot, source.tracks.indices.contains(trackIndex)
        else { return [] }
        return source.tracks[trackIndex].primitives.compactMap { primitive in
            guard case .detail(let detail) = primitive else { return nil }
            return FocusLocation(trackIndex: trackIndex, detail: detail)
        }.sorted {
            if $0.detail.range.startNs != $1.detail.range.startNs {
                return $0.detail.range.startNs < $1.detail.range.startNs
            }
            if $0.detail.eventKey.table.rawValue != $1.detail.eventKey.table.rawValue {
                return $0.detail.eventKey.table.rawValue < $1.detail.eventKey.table.rawValue
            }
            return $0.detail.eventKey.rowID < $1.detail.eventKey.rowID
        }
    }

    private func currentFocusLocation() -> FocusLocation? {
        guard let source = displayedSnapshot else { return nil }
        let key = focusedEventKey ?? selectedEventKey
        guard let key else { return nil }
        for (trackIndex, track) in source.tracks.enumerated() {
            for primitive in track.primitives {
                if case .detail(let detail) = primitive, detail.eventKey == key {
                    return FocusLocation(trackIndex: trackIndex, detail: detail)
                }
            }
        }
        return nil
    }

    private func focusedDetail() -> TimelineDetailPrimitive? {
        currentFocusLocation()?.detail
    }

    private func moveEvent(by delta: Int) -> Bool {
        guard let source = displayedSnapshot else { return false }
        let current = currentFocusLocation()
        let trackIndex = current?.trackIndex
            ?? source.tracks.firstIndex { track in
                track.primitives.contains { $0.selectableEventKey != nil }
            }
        guard let trackIndex else { return false }
        let locations = focusLocations(in: trackIndex)
        guard !locations.isEmpty else { return false }
        let index = current.flatMap { location in
            locations.firstIndex { $0.detail.eventKey == location.detail.eventKey }
        } ?? (delta < 0 ? locations.count : -1)
        let target = min(max(0, index + delta), locations.count - 1)
        return setFocus(locations[target])
    }

    private func canMoveEvent(by delta: Int) -> Bool {
        guard let source = displayedSnapshot else { return false }
        guard let current = currentFocusLocation() else {
            return source.tracks.indices.contains(where: {
                !focusLocations(in: $0).isEmpty
            })
        }
        let locations = focusLocations(in: current.trackIndex)
        guard let index = locations.firstIndex(where: {
            $0.detail.eventKey == current.detail.eventKey
        }) else { return false }
        return locations.indices.contains(index + delta)
    }

    private func moveTrack(by delta: Int) -> Bool {
        guard let source = displayedSnapshot else { return false }
        let current = currentFocusLocation()
        let origin = current?.trackIndex ?? (delta < 0 ? source.tracks.count : -1)
        var candidate = origin + delta
        while source.tracks.indices.contains(candidate) {
            let locations = focusLocations(in: candidate)
            if !locations.isEmpty {
                let anchor = current?.detail.range.startNs
                    ?? source.viewport.range.startNs
                let nearest = locations.min {
                    distance($0.detail.range.startNs, anchor)
                        < distance($1.detail.range.startNs, anchor)
                }!
                return setFocus(nearest)
            }
            candidate += delta
        }
        return false
    }

    private func canMoveTrack(by delta: Int) -> Bool {
        guard let source = displayedSnapshot else { return false }
        let current = currentFocusLocation()
        var candidate = (current?.trackIndex ?? (delta < 0 ? source.tracks.count : -1)) + delta
        while source.tracks.indices.contains(candidate) {
            if !focusLocations(in: candidate).isEmpty { return true }
            candidate += delta
        }
        return false
    }

    private func viewportIntent(for command: TimelineKeyboardCommand) -> TimelineViewportIntent? {
        guard let source = displayedSnapshot, let bounds = interactionBounds else { return nil }
        switch command {
        case .panBackward, .panForward:
            let points = source.viewport.widthPoints * 0.1
                * (command == .panBackward ? -1 : 1)
            let delta = source.viewport.nanosecondDelta(forPoints: points)
            guard let target = try? TimelineInteraction.pan(
                range: source.viewport.range, deltaNs: delta, within: bounds
            ), target != source.viewport.range else { return nil }
            return .panPoints(points, sourceViewport: source.viewport)
        case .zoomIn, .zoomOut, .zoomInAtPointer, .zoomOutAtPointer:
            let anchor = zoomAnchor(for: command, in: source)
            let scale = command == .zoomIn || command == .zoomInAtPointer ? 0.5 : 2.0
            guard let target = try? TimelineInteraction.zoom(
                range: source.viewport.range, anchorNs: anchor,
                scale: scale, within: bounds
            ), target != source.viewport.range else { return nil }
            return .zoom(anchorNs: anchor, scale: scale, sourceViewport: source.viewport)
        default:
            return nil
        }
    }

    /// `W` / `S` zoom about the pointer, as upstream does. The pointer is only
    /// an anchor while it is actually over the timeline; otherwise — pointer
    /// off the canvas, or the command arriving from assistive technology rather
    /// than from a key — these fall back to the same selection / focused-event
    /// / center chain the `+` and `-` keys use.
    private func zoomAnchor(
        for command: TimelineKeyboardCommand,
        in source: TimelineSnapshot
    ) -> Int64 {
        if command == .zoomInAtPointer || command == .zoomOutAtPointer,
            let pointerLocation, bounds.contains(pointerLocation)
        {
            return TimelineGeometry.time(forX: pointerLocation.x, viewport: source.viewport)
        }
        if let selection {
            return selection.startNs + selection.durationNs / 2
        }
        if let focused = focusedDetail() {
            return focused.range.startNs
        }
        return source.viewport.range.startNs + source.viewport.range.durationNs / 2
    }

    private func focus(eventKey: EventKey, notifyAccessibility: Bool = true) {
        guard let source = displayedSnapshot else { return }
        for (trackIndex, track) in source.tracks.enumerated() {
            for primitive in track.primitives {
                if case .detail(let detail) = primitive, detail.eventKey == eventKey {
                    _ = setFocus(
                        FocusLocation(trackIndex: trackIndex, detail: detail),
                        notifyAccessibility: notifyAccessibility
                    )
                    return
                }
            }
        }
    }

    private func setFocus(
        _ location: FocusLocation,
        notifyAccessibility: Bool = true
    ) -> Bool {
        guard focusedEventKey != location.detail.eventKey
            || focusedTrackID != location.detail.trackID
        else { return false }
        focusedEventKey = location.detail.eventKey
        focusedTrackID = location.detail.trackID
        needsDisplay = true
        if notifyAccessibility && !suppressAccessibilityNotifications {
            postAccessibilityValueChanged()
        }
        return true
    }

    private func postAccessibilityValueChanged() {
        accessibilityValueChangedHook?()
        unsafe NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func distance(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        if overflow { return UInt64.max }
        return value == Int64.min ? UInt64.max : UInt64(abs(value))
    }

    public var accessibilitySummary: String {
        guard let source = displayedSnapshot else { return "Timeline, no trace loaded" }
        var fields = [
            "Timeline",
            "viewport \(Self.timeLabel(source.viewport.range.startNs)) to \(Self.timeLabel(source.viewport.range.endNs))",
            "\(source.tracks.count) visible tracks",
        ]
        if let focused = currentFocusLocation() {
            let title = source.tracks[focused.trackIndex].descriptor.title
            fields.append("focused track \(title)")
            fields.append(Self.accessibleEventDescription(focused.detail))
        }
        if let selectedEventKey {
            fields.append(
                "selected event \(selectedEventKey.table.rawValue) \(selectedEventKey.rowID)"
            )
        }
        if let selection {
            fields.append(
                "selected range \(Self.timeLabel(selection.startNs)) to \(Self.timeLabel(selection.endNs))"
            )
        }
        if source.isLoading { fields.append("loading") }
        return fields.joined(separator: ", ")
    }

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .group }

    public override func accessibilityRoleDescription() -> String? { "timeline" }

    /// Host-supplied so the App can resolve it from its string catalog; a
    /// library target cannot without gaining a resource bundle (AT-APP-009).
    public var accessibilityLabelText = "Trace Timeline"

    public override func accessibilityLabel() -> String? { accessibilityLabelText }

    public override func accessibilityValue() -> Any? { accessibilitySummary }

    public override func accessibilityHelp() -> String? {
        "Use arrow keys to move between real events and tracks, Return to select, Option-Left or Option-Right to pan, plus or minus to zoom, W or S to zoom about the pointer, A or D to pan, F to zoom the selected range, 0 to reset, and Escape to clear selection."
    }

    public override func accessibilityChildren() -> [Any]? {
        // The bounded Timeline itself is the semantic element. Inspector and
        // Search provide full/copyable and list navigation alternatives.
        []
    }

    public override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let source = displayedSnapshot else { return [] }
        let hasEvents = source.tracks.contains { track in
            track.primitives.contains { $0.selectableEventKey != nil }
        }
        var actions: [NSAccessibilityCustomAction] = []
        if canMoveEvent(by: -1) {
            actions.append(accessibilityAction("Previous event", .previousEvent))
        }
        if canMoveEvent(by: 1) {
            actions.append(accessibilityAction("Next event", .nextEvent))
        }
        if canMoveTrack(by: -1) {
            actions.append(accessibilityAction("Previous track", .previousTrack))
        }
        if canMoveTrack(by: 1) {
            actions.append(accessibilityAction("Next track", .nextTrack))
        }
        if viewportIntent(for: .panBackward) != nil, onViewportIntent != nil {
            actions.append(accessibilityAction("Pan backward", .panBackward))
        }
        if viewportIntent(for: .panForward) != nil, onViewportIntent != nil {
            actions.append(accessibilityAction("Pan forward", .panForward))
        }
        if viewportIntent(for: .zoomIn) != nil, onViewportIntent != nil {
            actions.append(accessibilityAction("Zoom in", .zoomIn))
        }
        if viewportIntent(for: .zoomOut) != nil, onViewportIntent != nil {
            actions.append(accessibilityAction("Zoom out", .zoomOut))
        }
        if hasEvents && (focusedEventKey == nil || focusedEventKey != selectedEventKey
            || selection != nil)
        {
            actions.append(accessibilityAction("Select focused event", .selectFocusedEvent))
        }
        if let selection, selection != source.viewport.range, onZoomSelection != nil {
            actions.append(accessibilityAction("Zoom selected range", .zoomSelection))
        }
        if let interactionBounds, interactionBounds != source.viewport.range,
            onResetViewport != nil
        {
            actions.append(accessibilityAction("Reset viewport", .resetViewport))
        }
        if selectedEventKey != nil || focusedEventKey != nil || focusedTrackID != nil
            || selection != nil
        {
            actions.append(accessibilityAction("Clear selection", .clearSelection))
        }
        return actions
    }

    private func accessibilityAction(
        _ name: String,
        _ command: TimelineKeyboardCommand
    ) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self else { return false }
            return self.performKeyboardCommand(command)
        }
    }

    private static func accessibleEventDescription(
        _ detail: TimelineDetailPrimitive
    ) -> String {
        if let inspector = detail.inspector {
            var fields = [
                inspector.name ?? inspector.type.rawValue,
                "start \(timeLabel(inspector.range.startNs))",
                inspector.isOpenEnded
                    ? "open ended"
                    : "duration \(timeLabel(inspector.semanticDurationNs ?? 0))",
            ]
            if let process = inspector.processName { fields.append("process \(process)") }
            if let thread = inspector.threadName { fields.append("thread \(thread)") }
            if let cpu = inspector.cpu { fields.append("CPU \(cpu)") }
            return fields.joined(separator: ", ")
        }
        return "event \(detail.eventKey.table.rawValue) \(detail.eventKey.rowID), start \(timeLabel(detail.range.startNs)), duration \(timeLabel(detail.range.durationNs))"
    }

    private static func visualStyle(for category: String?) -> DetailVisualStyle {
        switch category {
        case "running", "cpu": return .running
        case "runnable": return .runnable
        case "blocked": return .blocked
        case "sleeping": return .sleeping
        case "counter": return .counter
        default: return .accent
        }
    }

    /// Identity color for a whole track, used by the aggregate density bands.
    /// Hashed from the stable track ID rather than the title so a track keeps
    /// its color across sessions and cannot change color when a thread name
    /// resolves late.
    private static func trackColor(for descriptor: TrackDescriptor) -> TimelineColor {
        TimelinePalette.trackIdentityColor(descriptor.id.rawValue)
    }

    private static func renderIdentity(
        current: TimelineSnapshot?, previous: TimelineSnapshot?
    ) -> RenderIdentity? {
        let displayed: TimelineSnapshot?
        if current?.isLoading == true {
            displayed = previous ?? current
        } else {
            displayed = current ?? previous
        }
        return displayed.map {
            RenderIdentity(generation: $0.generation, isLoading: $0.isLoading)
        }
    }

    /// Fixed three-fraction-digit style matching the previous
    /// `String(format: "%.3f")` output byte for byte: POSIX decimal point, no
    /// grouping separator, so canvas labels and accessibility values stay
    /// stable across user locales. A shared `FormatStyle` value is cheap to
    /// reuse per label; Foundation memoizes the backing formatter by style.
    private static let fixedFraction3 = FloatingPointFormatStyle<Double>(
        locale: Locale(identifier: "en_US_POSIX")
    )
    .precision(.fractionLength(3))
    .grouping(.never)

    private static func timeLabel(_ nanoseconds: Int64) -> String {
        if nanoseconds >= 1_000_000_000 {
            return fixedFraction3.format(Double(nanoseconds) / 1_000_000_000) + " s"
        }
        if nanoseconds >= 1_000_000 {
            return fixedFraction3.format(Double(nanoseconds) / 1_000_000) + " ms"
        }
        if nanoseconds >= 1_000 {
            return fixedFraction3.format(Double(nanoseconds) / 1_000) + " µs"
        }
        return "\(nanoseconds) ns"
    }
}

@MainActor
public struct TimelineView: NSViewRepresentable {
    public let snapshot: TimelineSnapshot?
    public let selection: TraceTimeRange?
    public let selectedEventKey: EventKey?
    public let focusRequestID: UInt64
    public let onSelectEvent: @MainActor (EventKey?) -> Void
    public let onHoverEvent: @MainActor (EventKey?) -> Void
    public let onSelectRange: @MainActor (TraceTimeRange?) -> Void
    public let onViewportIntent: @MainActor (TimelineViewportIntent) -> Void
    public let onZoomSelection: @MainActor () -> Void
    public let onResetViewport: @MainActor () -> Void
    public let interactionBounds: TraceTimeRange?
    /// Supplied by the host so it can come from the app's string catalog.
    public let accessibilityLabelText: String

    public init(
        snapshot: TimelineSnapshot?,
        selection: TraceTimeRange? = nil,
        selectedEventKey: EventKey? = nil,
        focusRequestID: UInt64 = 0,
        interactionBounds: TraceTimeRange? = nil,
        accessibilityLabelText: String = "Trace Timeline",
        onSelectEvent: @escaping @MainActor (EventKey?) -> Void = { _ in },
        onHoverEvent: @escaping @MainActor (EventKey?) -> Void = { _ in },
        onSelectRange: @escaping @MainActor (TraceTimeRange?) -> Void = { _ in },
        onViewportIntent: @escaping @MainActor (TimelineViewportIntent) -> Void = { _ in },
        onZoomSelection: @escaping @MainActor () -> Void = {},
        onResetViewport: @escaping @MainActor () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.selection = selection
        self.selectedEventKey = selectedEventKey
        self.focusRequestID = focusRequestID
        self.interactionBounds = interactionBounds
        self.accessibilityLabelText = accessibilityLabelText
        self.onSelectEvent = onSelectEvent
        self.onHoverEvent = onHoverEvent
        self.onSelectRange = onSelectRange
        self.onViewportIntent = onViewportIntent
        self.onZoomSelection = onZoomSelection
        self.onResetViewport = onResetViewport
    }

    public func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView(frame: .zero)
        view.accessibilityLabelText = accessibilityLabelText
        view.snapshot = snapshot
        view.selection = selection
        view.selectedEventKey = selectedEventKey
        view.onSelectEvent = onSelectEvent
        view.onHoverEvent = onHoverEvent
        view.onSelectRange = onSelectRange
        view.onViewportIntent = onViewportIntent
        view.onZoomSelection = onZoomSelection
        view.onResetViewport = onResetViewport
        view.interactionBounds = interactionBounds
        view.setAccessibilityIdentifier("arktrace.timeline")
        view.focusRingType = .default
        return view
    }

    public func updateNSView(_ view: TimelineNSView, context: Context) {
        view.accessibilityLabelText = accessibilityLabelText
        view.snapshot = snapshot
        view.selection = selection
        view.selectedEventKey = selectedEventKey
        view.onSelectEvent = onSelectEvent
        view.onHoverEvent = onHoverEvent
        view.onSelectRange = onSelectRange
        view.onViewportIntent = onViewportIntent
        view.onZoomSelection = onZoomSelection
        view.onResetViewport = onResetViewport
        view.interactionBounds = interactionBounds
        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.requestKeyboardFocus()
            }
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(lastFocusRequestID: focusRequestID)
    }

    public final class Coordinator {
        var lastFocusRequestID: UInt64

        init(lastFocusRequestID: UInt64) {
            self.lastFocusRequestID = lastFocusRequestID
        }
    }
}

public extension TimelineNSView {
    /// Shared focus restoration boundary used by the SwiftUI coordinator and
    /// hosted-window accessibility regressions.
    func requestKeyboardFocus() {
        unsafe window?.makeFirstResponder(self)
    }
}

public extension View {
    /// ArkTrace's shared minimum interactive target. The visual treatment may
    /// remain compact, while the actual hosted control frame is never smaller
    /// than the reviewed 24×24 point accessibility floor.
    func arktraceAccessibleTarget(
        minimum: CGFloat = TimelineAccessibilityLayout.minimumTargetPoints
    ) -> some View {
        frame(minWidth: minimum, minHeight: minimum)
            .contentShape(Rectangle())
    }
}
