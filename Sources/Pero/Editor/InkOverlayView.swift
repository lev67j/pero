import PDFKit

/// Transparent layer over the PDF that turns pen (or mouse) movement into strokes.
/// It never selects text or recognizes shapes: whatever you draw is what you get.
final class InkOverlayView: NSView {
    weak var pdfView: PDFView?
    var penWidth: Double = 1.5
    var penColor: NSColor = .black
    var onStrokeFinished: ((PDFPage, [CGPoint]) -> Void)?

    var isDrawingEnabled = true {
        didSet {
            guard oldValue != isDrawingEnabled else { return }
            if !isDrawingEnabled { cancelStroke() }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
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
        isDrawingEnabled ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing input

    override func mouseDown(with event: NSEvent) {
        guard let pdfView else { return }
        let inPDF = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inPDF, nearest: false) else {
            activePage = nil
            return
        }
        activePage = page
        pagePoints = [pdfView.convert(inPDF, to: page)]
        current = LiveStroke(points: [convert(event.locationInWindow, from: nil)],
                             width: CGFloat(penWidth) * pdfView.scaleFactor,
                             color: penColor)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pdfView, let page = activePage, var stroke = current else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.4 { return }
        stroke.points.append(point)
        current = stroke
        pagePoints.append(pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page))
        let recent = stroke.points.suffix(4)
        setNeedsDisplay(rect(around: Array(recent), padding: stroke.width + 2))
    }

    override func mouseUp(with event: NSEvent) {
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

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let stroke = current else { return }
        InkPath.stroke(stroke.points, width: stroke.width, color: stroke.color, in: context)
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
        guard isDrawingEnabled else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if isDrawingEnabled { Self.penCursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if isDrawingEnabled { Self.penCursor.set() }
    }
}
