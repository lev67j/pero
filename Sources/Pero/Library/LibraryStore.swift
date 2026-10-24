import SwiftUI

/// A folder or a document in the sidebar. Identified by its file path.
struct LibraryNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isFolder: Bool
    var style: FolderStyle
    /// nil for documents, so the sidebar shows no disclosure arrow for them.
    var children: [LibraryNode]?

    var id: String { url.path }
}

/// The library is a real folder tree on disk:
/// `~/Library/Application Support/Pero/Library/<folders>/<Name>.perodoc`.
@MainActor
final class LibraryStore: ObservableObject {
    let rootURL: URL
    @Published private(set) var nodes: [LibraryNode] = []
    private(set) var index: [String: LibraryNode] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent("Pero/Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        var newIndex: [String: LibraryNode] = [:]
        nodes = scan(rootURL, into: &newIndex)
        index = newIndex
    }

    func node(_ path: String?) -> LibraryNode? {
        path.flatMap { index[$0] }
    }

    /// All folders, depth-first, with their nesting level (for "Move to" menus).
    var allFolders: [(node: LibraryNode, depth: Int)] {
        var result: [(LibraryNode, Int)] = []
        func walk(_ list: [LibraryNode], _ depth: Int) {
            for n in list where n.isFolder {
                result.append((n, depth))
                walk(n.children ?? [], depth + 1)
            }
        }
        walk(nodes, 0)
        return result
    }

    // MARK: - Changes

    @discardableResult
    func createFolder(named name: String, in parent: URL) throws -> URL {
        let url = FileNames.uniqueURL(in: parent, name: name, pathExtension: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns the new URL.
    func rename(_ node: LibraryNode, to newName: String) throws -> URL {
        let parent = node.url.deletingLastPathComponent()
        let target = FileNames.uniqueURL(in: parent, name: newName,
                                         pathExtension: node.isFolder ? nil : DocumentPackage.fileExtension,
                                         ignoring: node.url)
        if target.path != node.url.path {
            try FileManager.default.moveItem(at: node.url, to: target)
        }
        return target
    }

    /// Moves a folder or document into `folder`. Returns the new URL, or nil if nothing moved.
    func move(_ url: URL, into folder: URL) throws -> URL? {
        let source = url.standardizedFileURL
        let destinationFolder = folder.standardizedFileURL
        if source.deletingLastPathComponent().path == destinationFolder.path { return nil }
        if destinationFolder.path == source.path || destinationFolder.path.hasPrefix(source.path + "/") { return nil }
        let isDocument = DocumentPackage.isPackage(source)
        let name = isDocument ? source.deletingPathExtension().lastPathComponent : source.lastPathComponent
        let target = FileNames.uniqueURL(in: destinationFolder, name: name,
                                         pathExtension: isDocument ? DocumentPackage.fileExtension : nil)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    /// Moves to the system Trash, so it can be restored from there.
    func trash(_ node: LibraryNode) throws {
        try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
    }

    func setStyle(_ style: FolderStyle, for node: LibraryNode) {
        style.save(to: node.url)
    }

    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/")
    }

    // MARK: - Scanning

    private func scan(_ folder: URL, into index: inout [String: LibraryNode]) -> [LibraryNode] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var folders: [LibraryNode] = []
        var documents: [LibraryNode] = []
        for name in names where !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            let url = folder.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if DocumentPackage.isPackage(url) {
                let node = LibraryNode(url: url, name: url.deletingPathExtension().lastPathComponent,
                                       isFolder: false, style: FolderStyle(), children: nil)
                index[node.id] = node
                documents.append(node)
            } else {
                let children = scan(url, into: &index)
                let node = LibraryNode(url: url, name: name, isFolder: true,
                                       style: FolderStyle.load(from: url), children: children)
                index[node.id] = node
                folders.append(node)
            }
        }
        let byName: (LibraryNode, LibraryNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: byName) + documents.sorted(by: byName)
    }
}
