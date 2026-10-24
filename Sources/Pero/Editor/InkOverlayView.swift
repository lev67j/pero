import PDFKit

/// Transparent layer over the PDF that turns pen, mouse or finger movement into strokes.
/// It never selects text or recognizes shapes: whatever you draw is what you get.
final class InkOverlayView: NSView {
    enum Mode {
        /// Clicks go to the PDF: text selection, links.
        case off
        /// Pen of a graphics tablet or the mouse: draws while the button is pressed.
        case pen
        /// The trackpad works like a small tablet: one finger draws where it touches,
        /// two fingers scroll. Like signing with a finger in Preview.
        case trackpad
    }

    weak var pdfView: PDFView?
    var penWidth: Double = 1.5
    var penColor: NSColor = .black
    var onStrokeFinished: ((PDFPage, [CGPoint]) -> Void)?
    /// Esc in trackpad mode.
    var onLeaveTrackpad: (() -> Void)?
    /// Turned off only by tests, so a test run doesn't take over the real pointer.
    var capturesPointer = true

    var mode: Mode = .pen {
        didSet {
            guard oldValue != mode else { return }
            cancelStroke()
            fingerPoint = nil
            allowedTouchTypes = mode == .trackpad ? [.indirect] : []
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
            updatePointerCapture()
            needsDisplay = true
        }
    }

    private struct LiveStroke {
        var points: [CGPoint]
        var width: CGFloat
        var color: NSColor
    }

    /// The stroke being drawn right now, in this view's coordinates. Once the pen
    /// lifts it is handed over and its page's ink view draws it from then on.
    private var activePage: PDFPage?
    private var pagePoints: [CGPoint] = []
    private var current: LiveStroke?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        mode == .off ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Strokes

    @discardableResult
    private func beginStroke(at point: NSPoint) -> Bool {
        guard let pdfView else { return false }
        let inPDF = convert(point, to: pdfView)
        guard let page = pdfView.page(for: inPDF, nearest: false) else {
            cancelStroke()
            return false
        }
        activePage = page
        pagePoints = [pdfView.convert(inPDF, to: page)]
        current = LiveStroke(points: [point], width: CGFloat(penWidth) * pdfView.scaleFactor, color: penColor)
        needsDisplay = true
        return true
    }

    private func extendStroke(to point: NSPoint) {
        guard let pdfView, let page = activePage, var stroke = current else { return }
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.4 { return }
        stroke.points.append(point)
        current = stroke
        pagePoints.append(pdfView.convert(convert(point, to: pdfView), to: page))
        setNeedsDisplay(rect(around: Array(stroke.points.suffix(4)), padding: stroke.width + 2))
    }

    private func finishStroke() {
        guard let page = activePage, current != nil else { return }
        let points = pagePoints
        cancelStroke()
        // The page's ink view redraws in the same display pass, so nothing flickers.
        onStrokeFinished?(page, points)
    }

    private func cancelStroke() {
        activePage = nil
        current = nil
        pagePoints = []
        needsDisplay = true
    }

    // MARK: - Pen and mouse

    override func mouseDown(with event: NSEvent) {
        // In trackpad mode clicks (and tap-to-click) are ignored: the finger draws.
        guard mode == .pen else { return }
        beginStroke(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .pen else { return }
        extendStroke(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .pen else { return }
        finishStroke()
    }

    // MARK: - Finger on the trackpad

    /// One touch as the stroke logic sees it. `position` is normalized to the
    /// trackpad, 0...1 with the origin at the bottom left.
    struct Finger {
        let id: AnyHashable
        let phase: NSTouch.Phase
        let position: CGPoint
    }

    private var fingerID: AnyHashable?
    private var fingerStrokeStart: TimeInterval = 0
    /// After two fingers touched (scroll, zoom) nothing is drawn until all fingers lift.
    private var waitsForAllFingersUp = false
    /// Where the finger is, shown as a dot instead of the hidden pointer.
    private var fingerPoint: NSPoint?
    private var trackpadAspect: CGFloat = 1.6

    /// The part of the view the whole trackpad maps onto, with the trackpad's proportions.
    /// Kept clear of the page switcher on the right edge.
    var trackpadArea: NSRect {
        let box = bounds.insetBy(dx: 70, dy: 16)
        guard box.width > 0, box.height > 0 else { return box }
        var width = box.width
        var height = width / trackpadAspect
        if height > box.height {
            height = box.height
            width = height * trackpadAspect
        }
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    private func point(onTrackpad position: CGPoint) -> NSPoint {
        let area = trackpadArea
        return NSPoint(x: area.minX + position.x * area.width, y: area.minY + position.y * area.height)
    }

    override func touchesBegan(with event: NSEvent) { touchesChanged(event) }
    override func touchesMoved(with event: NSEvent) { touchesChanged(event) }
    override func touchesEnded(with event: NSEvent) { touchesChanged(event) }
    override func touchesCancelled(with event: NSEvent) { touchesChanged(event) }

    private func touchesChanged(_ event: NSEvent) {
        guard mode == .trackpad else { return }
        let touches = event.touches(matching: .any, in: self)
        if let size = touches.first?.deviceSize, size.width > 0, size.height > 0,
           abs(size.width / size.height - trackpadAspect) > 0.01 {
            trackpadAspect = size.width / size.height
            needsDisplay = true
        }
        handleFingers(touches.map { touch in
            Finger(id: AnyHashable(touch.identity as! NSObject), phase: touch.phase, position: touch.normalizedPosition)
        }, at: event.timestamp)
    }

    /// Stroke logic for trackpad touches: one finger draws, two or more never do.
    func handleFingers(_ fingers: [Finger], at time: TimeInterval) {
        guard mode == .trackpad else { return }
        let down = fingers.filter { $0.phase != .ended && $0.phase != .cancelled }

        if down.isEmpty {
            if fingers.contains(where: { $0.id == fingerID && $0.phase == .cancelled }) {
                cancelStroke()
            } else {
                finishStroke()
            }
            fingerID = nil
            waitsForAllFingersUp = false
            fingerPoint = nil
            needsDisplay = true
            return
        }

        if down.count > 1 {
            // A second finger right after the first one means scrolling, not writing.
            if current != nil {
                if time - fingerStrokeStart < 0.15 { cancelStroke() } else { finishStroke() }
            }
            fingerID = nil
            waitsForAllFingersUp = true
            fingerPoint = nil
            needsDisplay = true
            return
        }

        let finger = down[0]
        let point = point(onTrackpad: finger.position)
        if let fingerID, fingerID != finger.id {
            // The drawing finger lifted while another one stays: stop here.
            finishStroke()
            self.fingerID = nil
            waitsForAllFingersUp = true
        }
        if waitsForAllFingersUp { return }

        let oldDot = fingerPoint
        fingerPoint = point
        if fingerID == nil {
            guard finger.phase == .began else { return }
            fingerID = finger.id
            fingerStrokeStart = time
            beginStroke(at: point)
        } else {
            extendStroke(to: point)
        }
        if let oldDot { setNeedsDisplay(dotRect(oldDot)) }
        setNeedsDisplay(dotRect(point))
    }

    private func dotRect(_ p: NSPoint) -> NSRect {
        let r = max(6, CGFloat(penWidth) * (pdfView?.scaleFactor ?? 1)) + 4
        return NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
    }

    // MARK: - Pointer capture in trackpad mode

    private var pointerCaptured = false
    private var escMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePointerCapture() }
                })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePointerCapture() }
                })
            }
        }
        updatePointerCapture()
    }

    /// In trackpad mode the pointer stays still and hidden over the page, so every
    /// touch reaches this view and the finger position alone decides where ink goes.
    private func updatePointerCapture() {
        let wanted = mode == .trackpad && capturesPointer && window?.isKeyWindow == true && NSApp.isActive
        if wanted && !pointerCaptured, let window {
            let center = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: center.x, y: primaryHeight - center.y))
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            pointerCaptured = true
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event } // Esc
                MainActor.assumeIsolated { self?.onLeaveTrackpad?() }
                return nil
            }
        } else if !wanted {
            releasePointer()
        }
    }

    private func releasePointer() {
        guard pointerCaptured else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        pointerCaptured = false
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    deinit {
        MainActor.assumeIsolated {
            releasePointer()
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if mode == .trackpad {
            // The area the trackpad maps onto.
            let outline = NSBezierPath(roundedRect: trackpadArea, xRadius: 14, yRadius: 14)
            outline.lineWidth = 1.5
            outline.setLineDash([6, 5], count: 2, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            outline.stroke()
        }
        if let stroke = current {
            InkPath.stroke(stroke.points, width: stroke.width, color: stroke.color, in: context)
        }
        if mode == .trackpad, let p = fingerPoint {
            let r = max(3, CGFloat(penWidth) * (pdfView?.scaleFactor ?? 1) / 2 + 1.5)
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            NSColor.white.setStroke()
            dot.lineWidth = 2
            dot.stroke()
            penColor.setFill()
            dot.fill()
        }
    }

    private func rect(around points: [CGPoint], padding: CGFloat) -> NSRect {
        guard let first = points.first else { return .zero }
        var r = NSRect(origin: first, size: .zero)
        for p in points { r = r.union(NSRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -padding, dy: -padding)
    }

    // MARK: - Scroll and zoom go to the PDF

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = pdfView?.documentView?.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            pdfView?.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let pdfView else { return }
        let scale = pdfView.scaleFactor * (1 + event.magnification)
        pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    override func smartMagnify(with event: NSEvent) {
        pdfView?.smartMagnify(with: event)
    }

    // MARK: - Cursor

    private static let penCursor: NSCursor = {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 5, y: 5))
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard mode == .pen else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if mode == .pen { Self.penCursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if mode == .pen { Self.penCursor.set() }
    }
}
