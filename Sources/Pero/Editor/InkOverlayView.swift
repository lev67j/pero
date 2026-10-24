import PDFKit

/// Transparent layer over the PDF that turns pen (or mouse) movement into strokes.
/// It never selects text or recognizes shapes: whatever you draw is what you get.
final class InkOverlayView: NSView {
    weak var pdfView: PDFView?
    var brush: Brush = .pen
    var penWidth: Double = 1.5
    var penColor: NSColor = .black
    /// Page, points in page space, and the id the stroke must keep (its texture depends on it).
    var onStrokeFinished: ((PDFPage, [CGPoint], UUID) -> Void)?
    var onEraseBegan: (() -> Void)?
    /// Page, eraser segment in page space, eraser radius in page space.
    var onErase: ((PDFPage, CGPoint, CGPoint, CGFloat) -> Void)?
    var onEraseEnded: (() -> Void)?

    var isDrawingEnabled = true {
        didSet {
            guard oldValue != isDrawingEnabled else { return }
            if !isDrawingEnabled { cancelStroke() }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }

    private struct LiveStroke {
        let id: UUID
        var points: [CGPoint]
        var width: CGFloat
        var color: NSColor
        var brush: Brush
    }

    /// The stroke being drawn right now, in this view's coordinates. Once the pen
    /// lifts it is handed over and its page's ink view draws it from then on.
    private var activePage: PDFPage?
    private var pagePoints: [CGPoint] = []
    private var current: LiveStroke?
    private var trackingArea: NSTrackingArea?
    /// Last eraser position, in page space of `activePage`.
    private var lastErasePoint: CGPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDrawingEnabled ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if brush == .eraser {
            onEraseBegan?()
            lastErasePoint = nil
            erase(at: point)
            return
        }
        guard let pdfView else { return }
        let inPDF = convert(point, to: pdfView)
        guard let page = pdfView.page(for: inPDF, nearest: false) else {
            cancelStroke()
            return
        }
        activePage = page
        pagePoints = [pdfView.convert(inPDF, to: page)]
        current = LiveStroke(id: UUID(), points: [point], width: CGFloat(penWidth) * pdfView.scaleFactor,
                             color: penColor, brush: brush)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if brush == .eraser {
            erase(at: point)
            return
        }
        guard let pdfView, let page = activePage, var stroke = current else { return }
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.4 { return }
        stroke.points.append(point)
        current = stroke
        pagePoints.append(pdfView.convert(convert(point, to: pdfView), to: page))
        setNeedsDisplay(tailRect(of: stroke))
    }

    override func mouseUp(with event: NSEvent) {
        if brush == .eraser {
            onEraseEnded?()
            lastErasePoint = nil
            activePage = nil
            return
        }
        guard let page = activePage, let stroke = current else { return }
        let points = pagePoints
        cancelStroke()
        // The page's ink view redraws in the same display pass, so nothing flickers.
        onStrokeFinished?(page, points, stroke.id)
    }

    private func cancelStroke() {
        activePage = nil
        current = nil
        pagePoints = []
        needsDisplay = true
    }

    /// Everything a new point can change: brushes taper the last few widths.
    private func tailRect(of stroke: LiveStroke) -> NSRect {
        var covered: CGFloat = 0
        var tail: [CGPoint] = []
        for p in stroke.points.reversed() {
            if let last = tail.last { covered += hypot(p.x - last.x, p.y - last.y) }
            tail.append(p)
            if covered > stroke.width * 8 && tail.count > 4 { break }
        }
        return rect(around: tail, padding: stroke.width * 1.5 + 4)
    }

    // MARK: - Eraser

    private func erase(at point: NSPoint) {
        guard let pdfView else { return }
        let inPDF = convert(point, to: pdfView)
        guard let page = pdfView.page(for: inPDF, nearest: false) else {
            lastErasePoint = nil
            return
        }
        let pagePoint = pdfView.convert(inPDF, to: page)
        // Moving onto another page starts a fresh segment there.
        let from = page === activePage ? (lastErasePoint ?? pagePoint) : pagePoint
        activePage = page
        lastErasePoint = pagePoint
        onErase?(page, from, pagePoint, CGFloat(penWidth) / 2)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let stroke = current else { return }
        InkRenderer.draw(stroke.points, width: stroke.width, color: stroke.color, brush: stroke.brush,
                         seed: InkStroke.seed(for: stroke.id), in: context)
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

    private static var eraserCursors: [Int: NSCursor] = [:]

    /// A ring as big as the eraser at the current zoom.
    private var eraserCursor: NSCursor {
        let diameter = Int(min(max(CGFloat(penWidth) * (pdfView?.scaleFactor ?? 1), 6), 120).rounded())
        if let cursor = Self.eraserCursors[diameter] { return cursor }
        let side = CGFloat(diameter + 4)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor.white.withAlphaComponent(0.35).setFill()
            ring.fill()
            ring.lineWidth = 2.5
            NSColor.white.setStroke()
            ring.stroke()
            ring.lineWidth = 1
            NSColor.black.withAlphaComponent(0.75).setStroke()
            ring.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        Self.eraserCursors[diameter] = cursor
        return cursor
    }

    /// Call when the brush, width or zoom changes.
    func updateCursor() {
        guard isDrawingEnabled, let window, window.isKeyWindow,
              bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        (brush == .eraser ? eraserCursor : Self.penCursor).set()
    }

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
        if isDrawingEnabled { (brush == .eraser ? eraserCursor : Self.penCursor).set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if isDrawingEnabled { (brush == .eraser ? eraserCursor : Self.penCursor).set() }
    }
}
