import AppKit
import PDFKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let library = LibraryStore()

    /// Selected row in the sidebar (folder or document path).
    @Published var selection: String? {
        didSet {
            revealInSidebar(selection)
            selectionChanged()
        }
    }
    /// Folders open in the sidebar (paths), remembered between launches.
    @Published var expandedFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(expandedFolders), forKey: "expandedFolders") }
    }
    @Published private(set) var session: InkSession?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasUnsavedInk = false
    @Published private(set) var isExportingLibrary = false
    /// Path of a just-created folder whose name the sidebar should ask for.
    @Published var renameRequest: String?

    @Published var isPenEnabled = true
    /// One page at a time instead of one long scroll.
    @Published var singlePageMode: Bool {
        didSet { UserDefaults.standard.set(singlePageMode, forKey: "singlePageMode") }
    }
    @Published private(set) var currentPage = 0
    @Published private(set) var pageCount = 0

    @Published var brush: Brush {
        didSet { UserDefaults.standard.set(brush.rawValue, forKey: "brush") }
    }
    /// Each brush remembers its own width.
    @Published private(set) var brushWidths: [String: Double] {
        didSet { UserDefaults.standard.set(brushWidths, forKey: "brushWidths") }
    }
    var penWidth: Double {
        get { brushWidths[brush.rawValue] ?? brush.defaultWidth }
        set { brushWidths[brush.rawValue] = min(max(newValue, brush.widthRange.lowerBound), brush.widthRange.upperBound) }
    }
    @Published var penColor: String {
        didSet { UserDefaults.standard.set(penColor, forKey: "penColor") }
    }
    /// Colors the user picked in the system color panel and saved to the palette.
    @Published private(set) var customPenColors: [String] {
        didSet { UserDefaults.standard.set(customPenColors, forKey: "customPenColors") }
    }

    /// The colors Apple uses across its apps (system colors and their darker
    /// high-contrast variants), plus black, graphite, gray and white for ink.
    static let penColors: [PenColor] = [
        PenColor("#1C1C1E", "Чёрный"), PenColor("#48484A", "Графит"), PenColor("#8E8E93", "Серый"),
        PenColor("#FFFFFF", "Белый"), PenColor("#A2845E", "Коричневый"), PenColor("#FF3B30", "Красный"),
        PenColor("#FF9500", "Оранжевый"), PenColor("#FFCC00", "Жёлтый"), PenColor("#34C759", "Зелёный"),
        PenColor("#00C7BE", "Мятный"), PenColor("#30B0C7", "Бирюзовый"), PenColor("#32ADE6", "Голубой"),
        PenColor("#007AFF", "Синий"), PenColor("#5856D6", "Индиго"), PenColor("#AF52DE", "Фиолетовый"),
        PenColor("#FF2D55", "Розовый"), PenColor("#D70015", "Тёмно-красный"), PenColor("#248A3D", "Тёмно-зелёный"),
        PenColor("#0040DD", "Тёмно-синий"), PenColor("#8944AB", "Тёмно-фиолетовый"),
    ]

    weak var canvas: PDFCanvasView?
    private var autosaveTimer: Timer?
    private var lastSaveError: String?

    private init() {
        let defaults = UserDefaults.standard
        brush = defaults.string(forKey: "brush").flatMap(Brush.init(rawValue:)) ?? .pen
        var widths = defaults.dictionary(forKey: "brushWidths") as? [String: Double] ?? [:]
        // Version 1.0 had a single width, for the pen.
        let oldWidth = defaults.double(forKey: "penWidth")
        if widths[Brush.pen.rawValue] == nil, oldWidth > 0 { widths[Brush.pen.rawValue] = oldWidth }
        brushWidths = widths
        penColor = defaults.string(forKey: "penColor") ?? Self.penColors[0].hex
        customPenColors = defaults.stringArray(forKey: "customPenColors") ?? []
        singlePageMode = defaults.bool(forKey: "singlePageMode")
        expandedFolders = Set(defaults.stringArray(forKey: "expandedFolders") ?? [])
        startAutosave()
    }

    // MARK: - Autosave

    /// Saves the open document's handwriting every 5 seconds if anything changed.
    private func startAutosave() {
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.saveNow() }
        }
        // .common so it also fires while the pen is down (event tracking).
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    func saveNow() {
        guard let session else { return }
        do {
            try session.saveIfDirty()
            lastSaveError = nil
        } catch {
            if lastSaveError == nil {
                showAlert("Не удалось сохранить записи", error.localizedDescription)
            }
            lastSaveError = error.localizedDescription
        }
        hasUnsavedInk = session.isDirty
    }

    // MARK: - Opening documents

    /// Opens every folder above the item so a new folder, an import or a moved file is visible.
    private func revealInSidebar(_ path: String?) {
        guard let path else { return }
        let root = library.rootURL.path
        var folder = (path as NSString).deletingLastPathComponent
        var missing: Set<String> = []
        while folder.hasPrefix(root + "/") {
            if !expandedFolders.contains(folder) { missing.insert(folder) }
            folder = (folder as NSString).deletingLastPathComponent
        }
        if !missing.isEmpty { expandedFolders.formUnion(missing) }
    }

    private func selectionChanged() {
        guard let node = library.node(selection), !node.isFolder else { return }
        open(node.url)
    }

    private func open(_ package: URL) {
        if session?.packageURL.path == package.path { return }
        closeSession()
        do {
            let newSession = try InkSession(packageURL: package)
            session = newSession
            if let warning = newSession.loadWarning {
                showAlert("Записи в этом файле не прочитались", warning)
            }
        } catch {
            showAlert("Не удалось открыть файл", error.localizedDescription)
        }
        refreshState()
    }

    private func closeSession() {
        saveNow()
        session = nil
        refreshState()
    }

    private func refreshState() {
        canUndo = session?.canUndo ?? false
        canRedo = session?.canRedo ?? false
        hasUnsavedInk = session?.isDirty ?? false
    }

    // MARK: - Pen

    func addStroke(on page: PDFPage, points: [CGPoint], id: UUID = UUID()) {
        guard let session, let document = page.document, document === session.document, brush != .eraser else { return }
        let stroke = InkStroke(id: id, page: document.index(for: page), color: penColor, width: penWidth,
                               brush: brush, points: points)
        if let page = session.add(stroke) { canvas?.refresh(page, reveal: false) }
        refreshState()
    }

    func beginErasing() {
        session?.beginErasing()
    }

    func erase(on page: PDFPage, from: CGPoint, to: CGPoint, radius: CGFloat) {
        guard let session, let document = page.document, document === session.document else { return }
        if session.erase(onPage: document.index(for: page), from: from, to: to, radius: radius) {
            canvas?.refresh(page, reveal: false)
            refreshState()
        }
    }

    func endErasing() {
        session?.endErasing()
        refreshState()
    }

    func undo() {
        guard let pages = session?.undo(), !pages.isEmpty else { return }
        for (i, page) in pages.enumerated() { canvas?.refresh(page, reveal: i == 0) }
        refreshState()
    }

    func redo() {
        guard let pages = session?.redo(), !pages.isEmpty else { return }
        for (i, page) in pages.enumerated() { canvas?.refresh(page, reveal: i == 0) }
        refreshState()
    }

    func zoom(by factor: CGFloat) { canvas?.zoom(by: factor) }
    func zoomToFit() { canvas?.zoomToFit() }

    // MARK: - Pages

    func pageChanged(to index: Int, of count: Int) {
        currentPage = index
        pageCount = count
    }

    func nextPage() { canvas?.goToNextPage() }
    func previousPage() { canvas?.goToPreviousPage() }

    // MARK: - Colors

    /// Saves the current color to "My colors" (newest first).
    func saveCurrentColor() {
        let hex = penColor.uppercased()
        guard !Self.penColors.contains(where: { $0.hex == hex }) else { return }
        customPenColors.removeAll { $0 == hex }
        customPenColors.insert(hex, at: 0)
        if customPenColors.count > 30 { customPenColors.removeLast(customPenColors.count - 30) }
    }

    func removeCustomColor(_ hex: String) {
        customPenColors.removeAll { $0 == hex }
    }

    var isCurrentColorSaved: Bool {
        let hex = penColor.uppercased()
        return Self.penColors.contains { $0.hex == hex } || customPenColors.contains(hex)
    }

    /// Opens the standard macOS color panel; whatever is picked there becomes the pen color.
    func openColorPanel() {
        ColorPanelBridge.shared.open(with: NSColor(hex: penColor) ?? .black) { [weak self] color in
            self?.penColor = color.hexString
        }
    }

    // MARK: - Library changes

    /// Folder that new folders and imports go into: the selected folder,
    /// the folder of the selected document, or the library root.
    var targetFolder: URL {
        guard let node = library.node(selection) else { return library.rootURL }
        return node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    func createFolder(in parent: URL? = nil) {
        do {
            let url = try library.createFolder(named: "Новая папка", in: parent ?? targetFolder)
            library.reload()
            selection = url.path
            renameRequest = url.path
        } catch {
            showAlert("Не удалось создать папку", error.localizedDescription)
        }
    }

    func rename(_ node: LibraryNode, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        relocate(node.url) { try self.library.rename(node, to: trimmed) }
    }

    func move(_ url: URL, into folder: URL) {
        relocate(url) { try self.library.move(url, into: folder) }
    }

    func trash(_ node: LibraryNode) {
        if let open = session?.packageURL.path, open == node.id || open.hasPrefix(node.id + "/") {
            closeSession()
        }
        do {
            try library.trash(node)
        } catch {
            showAlert("Не удалось удалить", error.localizedDescription)
        }
        library.reload()
        if library.node(selection) == nil { selection = nil }
    }

    func setStyle(_ style: FolderStyle, for node: LibraryNode) {
        library.setStyle(style, for: node)
        library.reload()
    }

    /// Runs a rename/move and keeps the open document and the selection pointing at the moved item.
    private func relocate(_ oldURL: URL, operation: () throws -> URL?) {
        let oldPath = oldURL.path
        let openPath = session?.packageURL.path
        let openIsInside = openPath.map { $0 == oldPath || $0.hasPrefix(oldPath + "/") } ?? false
        if openIsInside { closeSession() }
        do {
            guard let newURL = try operation() else {
                if openIsInside, let openPath { open(URL(fileURLWithPath: openPath, isDirectory: true)) }
                return
            }
            library.reload()
            let newPath = newURL.path
            func remap(_ path: String) -> String { newPath + path.dropFirst(oldPath.count) }
            let moved = expandedFolders.filter { $0 == oldPath || $0.hasPrefix(oldPath + "/") }
            if !moved.isEmpty {
                expandedFolders.subtract(moved)
                expandedFolders.formUnion(moved.map(remap))
            }
            if openIsInside, let openPath {
                open(URL(fileURLWithPath: remap(openPath), isDirectory: true))
            }
            if let selected = selection, selected == oldPath || selected.hasPrefix(oldPath + "/") {
                selection = remap(selected)
            }
        } catch {
            library.reload()
            if openIsInside, let openPath { open(URL(fileURLWithPath: openPath, isDirectory: true)) }
            showAlert("Не получилось", error.localizedDescription)
        }
    }

    // MARK: - Import

    func presentImportPanel(into folder: URL? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Импорт"
        panel.prompt = "Импортировать"
        panel.message = "PDF, Word, RTF, текст или картинки. Можно выбрать целую папку."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = DocumentImporter.contentTypes + [.folder]
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, into: folder)
    }

    /// Handles a drop: items already in the library are moved, everything else is imported.
    @discardableResult
    func handleDrop(_ urls: [URL], into folder: URL?) -> Bool {
        let target = folder ?? targetFolder
        var external: [URL] = []
        for url in urls {
            if library.contains(url) {
                move(url, into: target)
            } else {
                external.append(url)
            }
        }
        if !external.isEmpty { importFiles(external, into: target) }
        return true
    }

    func importFiles(_ urls: [URL], into folder: URL?) {
        let target = folder ?? targetFolder
        var created: [URL] = []
        var failures: [String] = []
        for url in urls {
            importItem(url, into: target, created: &created, failures: &failures, quietlySkip: false)
        }
        library.reload()
        if let first = created.first {
            selection = first.path
        }
        if !failures.isEmpty {
            showAlert("Часть файлов не импортирована", failures.joined(separator: "\n"))
        }
    }

    private func importItem(_ url: URL, into folder: URL, created: inout [URL], failures: inout [String], quietlySkip: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let ext = url.pathExtension.lowercased()

        if isDir.boolValue && ext == DocumentPackage.fileExtension {
            let target = FileNames.uniqueURL(in: folder, name: url.deletingPathExtension().lastPathComponent,
                                             pathExtension: DocumentPackage.fileExtension)
            do {
                try fm.copyItem(at: url, to: target)
                created.append(target)
            } catch {
                failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
            return
        }

        if isDir.boolValue && ext != "rtfd" {
            // A folder from Finder becomes a folder in the library, with everything inside.
            do {
                let subfolder = try library.createFolder(named: url.lastPathComponent, in: folder)
                let children = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
                for name in children.sorted() where !name.hasPrefix(".") {
                    importItem(url.appendingPathComponent(name), into: subfolder,
                               created: &created, failures: &failures, quietlySkip: true)
                }
            } catch {
                failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
            return
        }

        guard DocumentImporter.isSupported(url) else {
            if !quietlySkip { failures.append("\(url.lastPathComponent) — такой формат не поддерживается") }
            return
        }
        do {
            let data = try DocumentImporter.makePDF(from: url)
            let package = try DocumentPackage.create(in: folder, name: url.deletingPathExtension().lastPathComponent,
                                                     pdfData: data)
            created.append(package)
        } catch {
            failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    func exportCurrentDocument() {
        guard let session else { return }
        saveNow()
        let panel = NSSavePanel()
        panel.title = "Экспорт PDF"
        panel.prompt = "Экспортировать"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.displayName + ".pdf"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Exporter.flattenedPDF(package: session.packageURL)
            try data.write(to: url, options: .atomic)
        } catch {
            showAlert("Не удалось экспортировать", error.localizedDescription)
        }
    }

    // MARK: - Library export folder

    private static let exportBookmarkKey = "exportFolderBookmark"

    /// Where the library was exported to. Remembered as a bookmark, so the folder is
    /// found again after the user moves or renames it.
    var exportFolder: URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.exportBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path),
              !url.path.contains("/.Trash/") else { return nil }
        if stale { rememberExportFolder(url) }
        return url
    }

    var hasExportFolder: Bool { UserDefaults.standard.data(forKey: Self.exportBookmarkKey) != nil }

    private func rememberExportFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.exportBookmarkKey)
        }
        objectWillChange.send()
    }

    /// One button: updates the export folder if there is one, otherwise creates it on the Desktop.
    func exportOrUpdateLibrary() {
        hasExportFolder ? updateExport() : exportLibraryToDesktop()
    }

    /// A new export folder on the Desktop.
    func exportLibraryToDesktop() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = FileNames.uniqueURL(in: desktop, name: "Перо — библиотека", pathExtension: nil)
        sync(to: destination, title: "Библиотека выгружена на рабочий стол")
    }

    /// Writes only what changed since the last export into the existing folder.
    func updateExport() {
        guard let folder = exportFolder else {
            askForLostExportFolder()
            return
        }
        sync(to: folder, title: "Папка с выгрузкой обновлена")
    }

    private func askForLostExportFolder() {
        let alert = NSAlert()
        alert.messageText = "Не нашли папку с выгрузкой"
        alert.informativeText = "Её могли удалить или перенести на другой диск. Укажите, где она сейчас, — даже если вы её переименовали, — и она обновится. Или выгрузите библиотеку заново."
        alert.addButton(withTitle: "Указать папку…")
        alert.addButton(withTitle: "Выгрузить заново")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: chooseExportFolder()
        case .alertSecondButtonReturn: exportLibraryToDesktop()
        default: break
        }
    }

    /// Lets the user point at the export folder (moved, renamed) or pick a new one.
    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Папка с выгрузкой"
        panel.message = "Укажите папку, куда выгружалась библиотека Пера. Её можно было переместить и переименовать."
        panel.prompt = "Обновить эту папку"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportFolder?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        let unsafe = [fm.homeDirectoryForCurrentUser,
                      fm.urls(for: .desktopDirectory, in: .userDomainMask)[0],
                      fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                      URL(fileURLWithPath: "/")].map(\.standardizedFileURL.path)
        let path = url.standardizedFileURL.path
        if unsafe.contains(path) {
            showAlert("Выберите отдельную папку",
                      "Библиотека выгружается в одну папку. Создайте для неё новую папку (кнопка «Новая папка» в окне выбора) или выберите ту, куда уже выгружали.")
            return
        }
        if path == library.rootURL.standardizedFileURL.path || path.hasPrefix(library.rootURL.standardizedFileURL.path + "/") {
            showAlert("Эта папка внутри библиотеки", "Выберите папку вне библиотеки Пера, например на рабочем столе.")
            return
        }
        if !LibraryExport.isExportFolder(url) {
            let isEmpty = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).allSatisfy { $0.hasPrefix(".") }
            if !isEmpty {
                let confirm = NSAlert()
                confirm.messageText = "В этой папке нет выгрузки Пера"
                confirm.informativeText = "Выгрузить библиотеку в «\(url.lastPathComponent)»? Ваши файлы в ней останутся на месте; PDF с такими же именами, как у документов библиотеки, переместятся в Корзину."
                confirm.addButton(withTitle: "Выгрузить сюда")
                confirm.addButton(withTitle: "Отмена")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        sync(to: url, title: "Папка с выгрузкой обновлена")
    }

    private func sync(to destination: URL, title: String) {
        guard !isExportingLibrary else { return }
        saveNow()
        let root = library.rootURL
        isExportingLibrary = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try LibraryExport.sync(library: root, to: destination) }
            await MainActor.run {
                let model = AppModel.shared
                model.isExportingLibrary = false
                switch result {
                case .success(let summary):
                    model.rememberExportFolder(destination)
                    let alert = NSAlert()
                    alert.messageText = summary.changedAnything || summary.unchanged == 0 ? title : "Папка с выгрузкой уже актуальна"
                    alert.informativeText = model.describe(summary, folder: destination)
                    alert.addButton(withTitle: "Готово")
                    alert.addButton(withTitle: "Показать в Finder")
                    if alert.runModal() == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                case .failure(let error):
                    model.showAlert("Не удалось выгрузить библиотеку", error.localizedDescription)
                }
            }
        }
    }

    private func describe(_ s: LibraryExport.Summary, folder: URL) -> String {
        var parts: [String] = []
        if s.added > 0 { parts.append("новых файлов: \(s.added)") }
        if s.updated > 0 { parts.append("обновлено: \(s.updated)") }
        if s.removed > 0 { parts.append("убрано в Корзину: \(s.removed)") }
        if s.unchanged > 0 { parts.append("без изменений: \(s.unchanged)") }
        let counts = parts.isEmpty ? "Библиотека пуста." : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
        let place = (folder.path as NSString).abbreviatingWithTildeInPath
        return "\(counts)\n\nПапка: \(place)\nЕё можно перемещать и переименовывать — кнопка «Обновить» всё равно её найдёт."
    }

    func revealLibraryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([library.rootURL])
    }

    // MARK: - Alerts

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
