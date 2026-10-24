import PDFKit

/// An open document: its PDF, its strokes, and step-by-step undo/redo.
@MainActor
final class InkSession {
    /// One step of "Back": a drawn stroke, or everything one eraser movement removed.
    private enum Change {
        case added(InkStroke)
        /// Erased strokes with the positions they had, in ascending order.
        case erased([(index: Int, stroke: InkStroke)])
    }

    let packageURL: URL
    let document: PDFDocument
    private(set) var strokes: [InkStroke]
    private var undoStack: [Change] = []
    private var redoStack: [Change] = []
    /// Strokes removed by the eraser movement in progress.
    private var erasing: [(index: Int, stroke: InkStroke)]?
    private(set) var isDirty = false
    /// Set when the saved ink could not be read (the file is kept aside).
    private(set) var loadWarning: String?

    var displayName: String { packageURL.deletingPathExtension().lastPathComponent }
    /// Strokes from earlier sessions can be taken back one by one too.
    var canUndo: Bool { !undoStack.isEmpty || !strokes.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(packageURL: URL) throws {
        self.packageURL = packageURL
        guard let document = PDFDocument(url: DocumentPackage.pdfURL(packageURL)) else {
            throw PeroError.cannotOpen(packageURL.deletingPathExtension().lastPathComponent)
        }
        self.document = document
        do {
            self.strokes = try DocumentPackage.loadInk(packageURL)
            DocumentPackage.backupInk(packageURL)
        } catch {
            self.strokes = []
            self.loadWarning = error.localizedDescription
        }
    }

    func strokes(onPage index: Int) -> [InkStroke] {
        strokes.filter { $0.page == index }
    }

    /// Returns the page the stroke landed on.
    @discardableResult
    func add(_ stroke: InkStroke) -> PDFPage? {
        strokes.append(stroke)
        undoStack.append(.added(stroke))
        redoStack.removeAll()
        isDirty = true
        return document.page(at: stroke.page)
    }

    // MARK: - Eraser

    func beginErasing() {
        erasing = []
    }

    /// Removes whole strokes on the page that the eraser segment `from`–`to`
    /// (page space, eraser `radius`) touches. Returns true if anything was erased.
    @discardableResult
    func erase(onPage page: Int, from: CGPoint, to: CGPoint, radius: CGFloat) -> Bool {
        let reach = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                           width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(dx: -radius, dy: -radius)
        let hit = strokes.indices.filter { i in
            let stroke = strokes[i]
            guard stroke.page == page, stroke.bounds.intersects(reach) else { return false }
            return Self.touches(stroke, from: from, to: to, radius: radius + CGFloat(stroke.width) / 2)
        }
        guard !hit.isEmpty else { return false }
        if erasing == nil { erasing = [] }
        for i in hit.reversed() {
            erasing?.append((index: i, stroke: strokes.remove(at: i)))
        }
        isDirty = true
        return true
    }

    /// Makes everything erased since `beginErasing` one step of "Back".
    func endErasing() {
        guard let removed = erasing else { return }
        erasing = nil
        guard !removed.isEmpty else { return }
        // Indices were taken one removal at a time; replaying the removals in reverse
        // order restores the original positions, which `undo` needs ascending.
        var restored = strokes
        for item in removed.reversed() { restored.insert(item.stroke, at: item.index) }
        let ids = Set(removed.map { $0.stroke.id })
        let original = restored.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, stroke: $0.element) }
        undoStack.append(.erased(original))
        redoStack.removeAll()
    }

    private static func touches(_ stroke: InkStroke, from: CGPoint, to: CGPoint, radius: CGFloat) -> Bool {
        let points = stroke.cgPoints
        if points.count == 1 { return distance(points[0], from, to) <= radius }
        for i in 1..<points.count where segmentDistance(points[i - 1], points[i], from, to) <= radius {
            return true
        }
        return false
    }

    /// Distance from `p` to the segment `a`–`b`.
    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Distance between segments `a`–`b` and `c`–`d` (zero if they cross).
    private static func segmentDistance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        func cross(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return 0 }
        return min(distance(a, c, d), distance(b, c, d), distance(c, a, b), distance(d, a, b))
    }

    // MARK: - Undo

    /// Takes back the last step. Returns the pages that changed.
    @discardableResult
    func undo() -> [PDFPage] {
        if let change = undoStack.popLast() {
            redoStack.append(change)
            isDirty = true
            switch change {
            case .added(let stroke):
                strokes.removeAll { $0.id == stroke.id }
                return pages([stroke])
            case .erased(let items):
                for item in items { strokes.insert(item.stroke, at: min(item.index, strokes.count)) }
                return pages(items.map(\.stroke))
            }
        }
        // Strokes saved in an earlier session: the newest goes first.
        guard let stroke = strokes.popLast() else { return [] }
        redoStack.append(.added(stroke))
        isDirty = true
        return pages([stroke])
    }

    /// Repeats the most recently undone step. Returns the pages that changed.
    @discardableResult
    func redo() -> [PDFPage] {
        guard let change = redoStack.popLast() else { return [] }
        undoStack.append(change)
        isDirty = true
        switch change {
        case .added(let stroke):
            strokes.append(stroke)
            return pages([stroke])
        case .erased(let items):
            let ids = Set(items.map { $0.stroke.id })
            strokes.removeAll { ids.contains($0.id) }
            return pages(items.map(\.stroke))
        }
    }

    private func pages(_ strokes: [InkStroke]) -> [PDFPage] {
        Set(strokes.map(\.page)).sorted().compactMap { document.page(at: $0) }
    }

    func saveIfDirty() throws {
        guard isDirty else { return }
        try DocumentPackage.saveInk(strokes, to: packageURL)
        isDirty = false
    }
}
