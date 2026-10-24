import SwiftUI

/// Icon and color of a folder, stored in `.pero-folder.json` inside it.
struct FolderStyle: Codable, Hashable {
    var icon: String = "folder"
    var color: String = FolderColor.blue.rawValue

    var folderColor: FolderColor { FolderColor(rawValue: color) ?? .blue }

    private static let fileName = ".pero-folder.json"

    static func load(from folder: URL) -> FolderStyle {
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let style = try? JSONDecoder().decode(FolderStyle.self, from: data) else { return FolderStyle() }
        return style
    }

    func save(to folder: URL) {
        let url = folder.appendingPathComponent(Self.fileName, isDirectory: false)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static let icons: [String] = [
        "folder", "book", "books.vertical", "graduationcap", "pencil", "doc.text",
        "briefcase", "building.2", "house", "star", "heart", "flag",
        "bookmark", "tray", "archivebox", "lightbulb", "music.note", "paintbrush",
        "function", "atom", "brain", "globe", "chart.bar", "person",
        "person.2", "calendar", "clock", "leaf", "flame", "bolt",
        "sparkles", "tag", "cart", "camera", "airplane", "hammer",
    ]
}

enum FolderColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}
