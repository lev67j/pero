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
    @Published var penWidth: Double {
        didSet { UserDefaults.standard.set(penWidth, forKey: "penWidth") }
    }
    @Published var penColor: String {
        didSet { UserDefaults.standard.set(penColor, forKey: "penColor") }
    }

    static let penColors = ["#1C1C1E", "#0A58CA", "#D0312D", "#1E8E3E", "#7B3FC4"]

    weak var canvas: PDFCanvasView?
    private var autosaveTimer: Timer?
    private var lastSaveError: String?

    private init() {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "penWidth")
        penWidth = width > 0 ? width : 1.5
        penColor = defaults.string(forKey: "penColor") ?? Self.penColors[0]
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

    func addStroke(on page: PDFPage, points: [CGPoint]) {
        guard let session, let document = page.document, document === session.document else { return }
        let stroke = InkStroke(page: document.index(for: page), color: penColor, width: penWidth, points: points)
        if let page = session.add(stroke) { canvas?.refresh(page, reveal: false) }
        refreshState()
    }

    func undo() {
        guard let page = session?.undo() else { return }
        canvas?.refresh(page, reveal: true)
        refreshState()
    }

    func redo() {
        guard let page = session?.redo() else { return }
        canvas?.refresh(page, reveal: true)
        refreshState()
    }

    func zoom(by factor: CGFloat) { canvas?.zoom(by: factor) }
    func zoomToFit() { canvas?.zoomToFit() }

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

    func exportLibraryToDesktop() {
        guard !isExportingLibrary else { return }
        saveNow()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = FileNames.uniqueURL(in: desktop, name: "Перо — библиотека \(formatter.string(from: Date()))",
                                              pathExtension: nil)
        let root = library.rootURL
        isExportingLibrary = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try Exporter.exportLibrary(from: root, to: destination) }
            await MainActor.run {
                let model = AppModel.shared
                model.isExportingLibrary = false
                switch result {
                case .success(let count):
                    let alert = NSAlert()
                    alert.messageText = "Библиотека выгружена на рабочий стол"
                    alert.informativeText = "Папка «\(destination.lastPathComponent)», PDF-файлов: \(count). Все папки и подпапки сохранены."
                    alert.addButton(withTitle: "Показать в Finder")
                    alert.addButton(withTitle: "Готово")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                case .failure(let error):
                    model.showAlert("Не удалось выгрузить библиотеку", error.localizedDescription)
                }
            }
        }
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
