import PDFKit

/// Shows the saved strokes of one page. PDFKit places it over the page and moves
/// it with scrolling and zoom; points are mapped through PDFKit itself, so rotated
/// and cropped pages line up too.
final class PageInkView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    /// Returns the strokes to draw for this page.
    var strokes: () -> [InkStroke] = { [] }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Page space → this view's coordinates.
    private var pageTransform: CGAffineTransform? {
        guard let pdfView, let page, window != nil else { return nil }
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            convert(pdfView.convert(CGPoint(x: x, y: y), from: page), from: pdfView)
        }
        let o = map(0, 0), x = map(100, 0), y = map(0, 100)
        return CGAffineTransform(a: (x.x - o.x) / 100, b: (x.y - o.y) / 100,
                                 c: (y.x - o.x) / 100, d: (y.y - o.y) / 100,
                                 tx: o.x, ty: o.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let transform = pageTransform else { return }
        context.concatenate(transform)
        for stroke in strokes() where stroke.bounds.applying(transform).intersects(dirtyRect) {
            InkPath.stroke(stroke.cgPoints, width: stroke.width, color: stroke.nsColor, in: context)
        }
    }
}
