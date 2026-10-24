import PDFKit

/// An open document: its PDF, its strokes, and stroke-by-stroke undo/redo.
@MainActor
final class InkSession {
    let packageURL: URL
    let document: PDFDocument
    private(set) var strokes: [InkStroke]
    private var redoStack: [InkStroke] = []
    private(set) var isDirty = false
    /// Set when the saved ink could not be read (the file is kept aside).
    private(set) var loadWarning: String?

    var displayName: String { packageURL.deletingPathExtension().lastPathComponent }
    var canUndo: Bool { !strokes.isEmpty }
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
        redoStack.removeAll()
        isDirty = true
        return document.page(at: stroke.page)
    }

    /// Removes the most recent stroke. Returns the page it was on.
    @discardableResult
    func undo() -> PDFPage? {
        guard let stroke = strokes.popLast() else { return nil }
        redoStack.append(stroke)
        isDirty = true
        return document.page(at: stroke.page)
    }

    /// Brings back the most recently undone stroke. Returns the page it is on.
    @discardableResult
    func redo() -> PDFPage? {
        guard let stroke = redoStack.popLast() else { return nil }
        strokes.append(stroke)
        isDirty = true
        return document.page(at: stroke.page)
    }

    func saveIfDirty() throws {
        guard isDirty else { return }
        try DocumentPackage.saveInk(strokes, to: packageURL)
        isDirty = false
    }
}
