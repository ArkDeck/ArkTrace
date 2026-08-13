import AppKit
import ArkTraceCore
import SwiftUI

@MainActor
public final class TimelineNSView: NSView {
    public var snapshot: TimelineSnapshot? {
        didSet {
            if snapshot == nil {
                previousSnapshot = nil
            } else if let oldValue, snapshot?.generation != oldValue.generation,
                snapshot?.isLoading == true
            {
                previousSnapshot = oldValue
            } else if let snapshot, !snapshot.isLoading {
                previousSnapshot = snapshot
            }
            needsDisplay = true
        }
    }
    public var selection: TraceTimeRange? { didSet { needsDisplay = true } }
    public var onSelectEvent: (@MainActor (EventKey?) -> Void)?
    public var onHoverEvent: (@MainActor (EventKey?) -> Void)?
    public var onSelectRange: (@MainActor (TraceTimeRange?) -> Void)?
    public var onViewportIntent: (@MainActor (TimelineViewportIntent) -> Void)?

    private var previousSnapshot: TimelineSnapshot?
    private var dragStartX: CGFloat?
    private var trackingAreaReference: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

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
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for track in source.tracks.reversed() {
            guard TimelineGeometry.trackFrame(track).contains(point) else { continue }
            for primitive in track.primitives.reversed() {
                guard let key = primitive.selectableEventKey else { continue }
                let frame = TimelineGeometry.frame(
                    for: primitive, in: track,
                    viewport: source.viewport, backingScale: scale
                )
                if frame.insetBy(dx: -1, dy: -1).contains(point) { return key }
            }
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let selected = self.event(at: point) {
            dragStartX = nil
            onSelectRange?(nil)
            onSelectEvent?(selected)
        } else {
            onSelectEvent?(nil)
            dragStartX = point.x
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
        dragStartX = nil
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHoverEvent?(self.event(at: point))
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

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
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
        context.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
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
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for (index, track) in snapshot.tracks.enumerated() {
            let trackFrame = TimelineGeometry.trackFrame(track)
            guard trackFrame.maxY >= dirtyRect.minY, trackFrame.minY <= dirtyRect.maxY else { continue }
            context.setFillColor(
                (index.isMultiple(of: 2)
                    ? NSColor.textBackgroundColor
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.45)).cgColor
            )
            context.fill(CGRect(x: 0, y: trackFrame.minY, width: bounds.width, height: trackFrame.height))
            for primitive in track.primitives {
                draw(
                    primitive,
                    frame: TimelineGeometry.frame(
                        for: primitive, in: track,
                        viewport: snapshot.viewport, backingScale: scale
                    ),
                    context: context
                )
            }
            context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1 / scale)
            context.move(to: CGPoint(x: 0, y: trackFrame.maxY))
            context.addLine(to: CGPoint(x: bounds.width, y: trackFrame.maxY))
            context.strokePath()
        }
    }

    private func draw(
        _ primitive: TimelinePrimitive,
        frame: CGRect,
        context: CGContext
    ) {
        switch primitive {
        case .detail(let detail):
            context.setFillColor(Self.color(for: detail.category).cgColor)
            context.fill(frame)
            guard let label = detail.label,
                frame.width >= TimelineGeometry.minimumLabelWidth
            else { return }
            context.saveGState()
            context.clip(to: frame.insetBy(dx: 1, dy: 1))
            label.draw(
                at: CGPoint(
                    x: frame.minX + TimelineGeometry.horizontalLabelInset,
                    y: frame.minY + max(1, (frame.height - 11) / 2)
                ),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.white,
                ]
            )
            context.restoreGState()
        case .density(let density):
            let alpha = min(0.9, 0.18 + log2(Double(max(1, density.bucket.eventCount))) * 0.1)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor)
            context.fill(frame)
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
    }

    private static func color(for category: String?) -> NSColor {
        switch category {
        case "running", "cpu": return .systemGreen
        case "runnable": return .systemOrange
        case "blocked": return .systemRed
        case "sleeping": return .systemBlue
        case "counter": return .systemPurple
        default: return .controlAccentColor
        }
    }

    private static func timeLabel(_ nanoseconds: Int64) -> String {
        if nanoseconds >= 1_000_000_000 {
            return String(format: "%.3f s", Double(nanoseconds) / 1_000_000_000)
        }
        if nanoseconds >= 1_000_000 {
            return String(format: "%.3f ms", Double(nanoseconds) / 1_000_000)
        }
        if nanoseconds >= 1_000 {
            return String(format: "%.3f µs", Double(nanoseconds) / 1_000)
        }
        return "\(nanoseconds) ns"
    }
}

@MainActor
public struct TimelineView: NSViewRepresentable {
    public let snapshot: TimelineSnapshot?
    public let selection: TraceTimeRange?
    public let onSelectEvent: @MainActor (EventKey?) -> Void
    public let onHoverEvent: @MainActor (EventKey?) -> Void
    public let onSelectRange: @MainActor (TraceTimeRange?) -> Void
    public let onViewportIntent: @MainActor (TimelineViewportIntent) -> Void

    public init(
        snapshot: TimelineSnapshot?,
        selection: TraceTimeRange? = nil,
        onSelectEvent: @escaping @MainActor (EventKey?) -> Void = { _ in },
        onHoverEvent: @escaping @MainActor (EventKey?) -> Void = { _ in },
        onSelectRange: @escaping @MainActor (TraceTimeRange?) -> Void = { _ in },
        onViewportIntent: @escaping @MainActor (TimelineViewportIntent) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.selection = selection
        self.onSelectEvent = onSelectEvent
        self.onHoverEvent = onHoverEvent
        self.onSelectRange = onSelectRange
        self.onViewportIntent = onViewportIntent
    }

    public func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView(frame: .zero)
        view.snapshot = snapshot
        view.selection = selection
        view.onSelectEvent = onSelectEvent
        view.onHoverEvent = onHoverEvent
        view.onSelectRange = onSelectRange
        view.onViewportIntent = onViewportIntent
        return view
    }

    public func updateNSView(_ view: TimelineNSView, context: Context) {
        view.snapshot = snapshot
        view.selection = selection
        view.onSelectEvent = onSelectEvent
        view.onHoverEvent = onHoverEvent
        view.onSelectRange = onSelectRange
        view.onViewportIntent = onViewportIntent
    }
}
