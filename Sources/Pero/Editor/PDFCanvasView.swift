import PDFKit
import SwiftUI

/// The PDF, shown like in Preview, with the ink on top.
final class PDFCanvasView: NSView, PDFPageOverlayViewProvider {
    let pdfView = PDFView()
    let overlay = InkOverlayView()
    private(set) var session: InkSession?
    /// Ink views of the pages PDFKit currently shows.
    private var inkViews: [ObjectIdentifier: PageInkView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pdfView.frame = bounds
        pdfView.autoresizingMask = [.width, .height]
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.enableDataDetectors = false
        pdfView.pageOverlayViewProvider = self
        addSubview(pdfView)

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.pdfView = pdfView
        addSubview(overlay)

        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged),
                                               name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
    }

    /// Current page index and page count, whenever the visible page changes.
    var onPageChanged: ((Int, Int) -> Void)?

    @objc private func pageChanged() {
        // Reported on the next turn: this also fires while SwiftUI is updating the view.
        DispatchQueue.main.async { [weak self] in
            guard let self, let document = pdfView.document, let page = pdfView.currentPage else { return }
            onPageChanged?(document.index(for: page), document.pageCount)
        }
    }

    /// One page at a time, or all pages as one long scroll.
    func setSinglePage(_ single: Bool) {
        let mode: PDFDisplayMode = single ? .singlePage : .singlePageContinuous
        guard pdfView.displayMode != mode else { return }
        let page = pdfView.currentPage
        pdfView.displayMode = mode
        pdfView.autoScales = true
        if let page { pdfView.go(to: page) }
    }

    func goToNextPage() { pdfView.goToNextPage(nil) }
    func goToPreviousPage() { pdfView.goToPreviousPage(nil) }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ session: InkSession) {
        guard self.session !== session else { return }
        self.session = session
        inkViews.removeAll()
        pdfView.document = session.document
        pdfView.autoScales = true
        window?.makeFirstResponder(pdfView)
        pageChanged()
    }

    /// Redraws a page after a stroke was added or removed, and scrolls to it if it is off-screen.
    func refresh(_ page: PDFPage, reveal: Bool) {
        inkViews[ObjectIdentifier(page)]?.needsDisplay = true
        if reveal && !pdfView.visiblePages.contains(page) {
            pdfView.go(to: page)
        }
    }

    @objc private func scaleChanged() {
        for view in inkViews.values { view.needsDisplay = true }
    }

    func zoom(by factor: CGFloat) {
        let scale = pdfView.scaleFactor * factor
        pdfView.scaleFactor = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    func zoomToFit() {
        pdfView.autoScales = true
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        if let existing = inkViews[ObjectIdentifier(page)] { return existing }
        let inkView = PageInkView()
        inkView.pdfView = view
        inkView.page = page
        inkView.strokes = { [weak self, weak page] in
            guard let session = self?.session, let page, page.document === session.document else { return [] }
            return session.strokes(onPage: session.document.index(for: page))
        }
        inkViews[ObjectIdentifier(page)] = inkView
        return inkView
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        inkViews.removeValue(forKey: ObjectIdentifier(page))
    }
}

struct PDFCanvas: NSViewRepresentable {
    let session: InkSession
    let tool: InkTool
    let singlePage: Bool
    let penWidth: Double
    let penColor: NSColor
    let onStroke: (PDFPage, [CGPoint]) -> Void
    let onPageChanged: (Int, Int) -> Void
    let onLeaveTrackpad: () -> Void
    let onAppear: (PDFCanvasView) -> Void

    func makeNSView(context: Context) -> PDFCanvasView {
        let view = PDFCanvasView(frame: .zero)
        view.setSinglePage(singlePage)
        onAppear(view)
        return view
    }

    func updateNSView(_ view: PDFCanvasView, context: Context) {
        view.onPageChanged = onPageChanged
        view.show(session)
        view.setSinglePage(singlePage)
        view.overlay.penWidth = penWidth
        view.overlay.penColor = penColor
        view.overlay.onStrokeFinished = onStroke
        view.overlay.onLeaveTrackpad = onLeaveTrackpad
        switch tool {
        case .pen: view.overlay.mode = .pen
        case .trackpad: view.overlay.mode = .trackpad
        case .cursor: view.overlay.mode = .off
        }
    }
}
