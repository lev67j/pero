import Foundation

enum PeroError: LocalizedError {
    case cannotOpen(String)
    case unsupportedFormat(String)
    case conversionFailed(String)
    case lockedPDF
    case brokenInk

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "Не удалось открыть «\(name)»."
        case .unsupportedFormat(let ext): return "Формат .\(ext) не поддерживается."
        case .conversionFailed(let name): return "Не удалось превратить «\(name)» в PDF."
        case .lockedPDF: return "PDF защищён паролем."
        case .brokenInk: return "Файл с записями повреждён. Копия сохранена рядом как ink.broken.json."
        }
    }
}

/// A document in the library is a folder `Name.perodoc` holding the original
/// `document.pdf` and the handwriting in `ink.json`.
enum DocumentPackage {
    static let fileExtension = "perodoc"

    static func pdfURL(_ package: URL) -> URL { package.appendingPathComponent("document.pdf", isDirectory: false) }
    static func inkURL(_ package: URL) -> URL { package.appendingPathComponent("ink.json", isDirectory: false) }
    private static func backupURL(_ package: URL) -> URL { package.appendingPathComponent("ink.backup.json", isDirectory: false) }

    static func isPackage(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }

    static func create(in folder: URL, name: String, pdfData: Data) throws -> URL {
        let package = FileNames.uniqueURL(in: folder, name: name, pathExtension: fileExtension)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        do {
            try pdfData.write(to: pdfURL(package), options: .atomic)
            try saveInk([], to: package)
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
        return package
    }

    static func loadInk(_ package: URL) throws -> [InkStroke] {
        let url = inkURL(package)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(InkFile.self, from: data).strokes
        } catch {
            // Keep the unreadable file instead of overwriting it later.
            let broken = package.appendingPathComponent("ink.broken.json", isDirectory: false)
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.copyItem(at: url, to: broken)
            throw PeroError.brokenInk
        }
    }

    static func saveInk(_ strokes: [InkStroke], to package: URL) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(InkFile(strokes: strokes))
        try data.write(to: inkURL(package), options: .atomic)
    }

    /// Copy of the ink as it was when the document was opened.
    static func backupInk(_ package: URL) {
        let source = inkURL(package)
        let backup = backupURL(package)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: source, to: backup)
    }
}

enum FileNames {
    /// Removes characters that can't be in a file name.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noDot = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        return noDot.isEmpty ? "Без названия" : noDot
    }

    /// `folder/name.ext`, or `folder/name 2.ext` etc. if taken.
    static func uniqueURL(in folder: URL, name: String, pathExtension: String?, isDirectory: Bool = true, ignoring current: URL? = nil) -> URL {
        let base = sanitize(name)
        func make(_ n: String) -> URL {
            let file = pathExtension.map { "\(n).\($0)" } ?? n
            return folder.appendingPathComponent(file, isDirectory: isDirectory)
        }
        var candidate = make(base)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.path != current?.path {
            candidate = make("\(base) \(i)")
            i += 1
        }
        return candidate
    }
}
