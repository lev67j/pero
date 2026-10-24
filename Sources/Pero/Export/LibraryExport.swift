import Foundation

/// The library as one ordinary folder: the same folders and subfolders, every document
/// as a PDF with its handwriting. Instead of exporting again, the folder can be brought
/// up to date: only new and changed documents are written.
///
/// A hidden `.pero-export.json` in the folder remembers what the export wrote, so files
/// the user put there are never touched, and files of removed documents go to the Trash.
enum LibraryExport {
    static let manifestName = ".pero-export.json"

    struct Summary {
        var added = 0
        var updated = 0
        var removed = 0
        var unchanged = 0

        var changedAnything: Bool { added + updated + removed > 0 }
    }

    private struct Manifest: Codable {
        var version = 1
        /// Exported PDF (path relative to the export folder) → what it was made from.
        var files: [String: Entry] = [:]
        /// Folders the export created (relative paths).
        var folders: [String] = []

        struct Entry: Codable {
            var source: String
            var fingerprint: String
            var written: Date
        }
    }

    static func isExportFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestName).path)
    }

    /// Brings `destination` in line with the library.
    /// `discard` takes away files the export no longer needs (the Trash, so nothing is lost).
    static func sync(library root: URL, to destination: URL,
                     discard: (URL) -> Void = { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> Summary {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifestURL = destination.appendingPathComponent(manifestName)
        var manifest = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))) ?? Manifest()
        var summary = Summary()
        var liveFiles: Set<String> = []
        var liveFolders: Set<String> = []

        func walk(_ folder: URL, relative: String) throws {
            let names = try fm.contentsOfDirectory(atPath: folder.path).sorted()
            for name in names where !name.hasPrefix(".") {
                let source = folder.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if DocumentPackage.isPackage(source) {
                    let file = join(relative, FileNames.sanitize(source.deletingPathExtension().lastPathComponent) + ".pdf")
                    liveFiles.insert(file)
                    try export(source, as: file)
                } else {
                    let sub = join(relative, name)
                    liveFolders.insert(sub)
                    let target = destination.appendingPathComponent(sub, isDirectory: true)
                    if !fm.fileExists(atPath: target.path) {
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    }
                    if !manifest.folders.contains(sub) { manifest.folders.append(sub) }
                    try walk(source, relative: sub)
                }
            }
        }

        func export(_ package: URL, as file: String) throws {
            let target = destination.appendingPathComponent(file, isDirectory: false)
            let fingerprint = Self.fingerprint(package)
            let entry = manifest.files[file]
            let exists = fm.fileExists(atPath: target.path)
            if let entry, exists, entry.fingerprint == fingerprint {
                summary.unchanged += 1
                return
            }
            if exists {
                // Changed outside Pero since the last export, or not ours at all: keep a copy in the Trash.
                let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let editedElsewhere = entry == nil || (modified.map { $0.timeIntervalSince(entry!.written) > 2 } ?? false)
                if editedElsewhere { discard(target) }
            }
            try Exporter.flattenedPDF(package: package).write(to: target, options: .atomic)
            manifest.files[file] = Manifest.Entry(source: relativePath(package, in: root), fingerprint: fingerprint, written: Date())
            if exists && entry != nil { summary.updated += 1 } else { summary.added += 1 }
        }

        try walk(root, relative: "")

        // Documents deleted or renamed in the library: their old PDFs go to the Trash.
        for file in manifest.files.keys.sorted() where !liveFiles.contains(file) {
            let target = destination.appendingPathComponent(file, isDirectory: false)
            if fm.fileExists(atPath: target.path) {
                discard(target)
                summary.removed += 1
            }
            manifest.files[file] = nil
        }
        // Folders gone from the library (deepest first): an empty one goes to the Trash,
        // one the user put files into stays and is simply no longer ours.
        for folder in manifest.folders.sorted(by: { $0.count > $1.count }) where !liveFolders.contains(folder) {
            let target = destination.appendingPathComponent(folder, isDirectory: true)
            let contents = (try? fm.contentsOfDirectory(atPath: target.path)) ?? []
            if fm.fileExists(atPath: target.path), contents.allSatisfy({ $0 == ".DS_Store" }) {
                discard(target)
            }
            manifest.folders.removeAll { $0 == folder }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return summary
    }

    /// Changes whenever the PDF or the handwriting of a document changes.
    private static func fingerprint(_ package: URL) -> String {
        [DocumentPackage.pdfURL(package), DocumentPackage.inkURL(package)].map { url -> String in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let time = Int(((values?.contentModificationDate?.timeIntervalSince1970) ?? 0) * 1000)
            return "\(size)@\(time)"
        }.joined(separator: "|")
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private static func relativePath(_ url: URL, in root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }
}
