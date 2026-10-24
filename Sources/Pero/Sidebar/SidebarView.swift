import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore

    @State private var renameTarget: LibraryNode?
    @State private var renameText = ""
    @State private var styleTarget: LibraryNode?
    @State private var deleteTarget: LibraryNode?

    var body: some View {
        List(selection: $model.selection) {
            LibraryRows(nodes: library.nodes, expanded: $model.expandedFolders, row: row)
        }
        .listStyle(.sidebar)
        .overlay {
            if library.nodes.isEmpty {
                Text("Здесь будут ваши папки и файлы")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, into: library.rootURL)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    model.createFolder()
                } label: {
                    Label("Новая папка", systemImage: "folder.badge.plus")
                }
                .help("Новая папка (⇧⌘N)")
                Button {
                    model.presentImportPanel()
                } label: {
                    Label("Импорт", systemImage: "square.and.arrow.down")
                }
                .help("Добавить файлы (⌘O)")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .onChange(of: model.renameRequest) { _, path in
            guard let path, let node = library.node(path) else { return }
            model.renameRequest = nil
            startRename(node)
        }
        .alert("Переименовать", isPresented: isPresented($renameTarget), presenting: renameTarget) { node in
            TextField("Название", text: $renameText)
            Button("Отмена", role: .cancel) {}
            Button("Готово") { model.rename(node, to: renameText) }
        }
        .confirmationDialog(deleteTitle, isPresented: isPresented($deleteTarget), presenting: deleteTarget) { node in
            Button("Переместить в Корзину", role: .destructive) { model.trash(node) }
            Button("Отмена", role: .cancel) {}
        } message: { node in
            Text(node.isFolder ? "Папка и всё, что в ней лежит, окажутся в Корзине. Оттуда их можно вернуть." :
                                 "Файл окажется в Корзине. Оттуда его можно вернуть.")
        }
        .sheet(item: $styleTarget) { node in
            FolderStyleEditor(node: node) { style in model.setStyle(style, for: node) }
        }
    }

    private var deleteTitle: String {
        guard let node = deleteTarget else { return "" }
        return "Удалить «\(node.name)»?"
    }

    private func row(_ node: LibraryNode) -> some View {
        Label {
            Text(node.name).lineLimit(1)
        } icon: {
            if node.isFolder {
                Image(systemName: node.style.icon)
                    .foregroundStyle(node.style.folderColor.color)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .draggable(node.url)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, into: node.isFolder ? node.url : node.url.deletingLastPathComponent())
        }
        .contextMenu { menu(for: node) }
    }

    @ViewBuilder
    private func menu(for node: LibraryNode) -> some View {
        if node.isFolder {
            Button("Новая папка внутри") { model.createFolder(in: node.url) }
            Button("Импортировать сюда…") { model.presentImportPanel(into: node.url) }
            Divider()
            Button("Значок и цвет…") { styleTarget = node }
        } else {
            Button("Экспортировать PDF…") {
                model.selection = node.id
                model.exportCurrentDocument()
            }
        }
        Button("Переименовать…") { startRename(node) }
        Menu("Переместить в") {
            Button("Библиотека (верхний уровень)") { model.move(node.url, into: library.rootURL) }
            let folders = library.allFolders.filter { $0.node.id != node.id && !$0.node.id.hasPrefix(node.id + "/") }
            if !folders.isEmpty { Divider() }
            ForEach(folders, id: \.node.id) { item in
                Button(String(repeating: "    ", count: item.depth) + item.node.name) {
                    model.move(node.url, into: item.node.url)
                }
            }
        }
        Divider()
        Button("Удалить…", role: .destructive) { deleteTarget = node }
    }

    private func startRename(_ node: LibraryNode) {
        renameText = node.name
        renameTarget = node
    }

    private func isPresented<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Folders and documents as a tree. Unlike OutlineGroup, which folders are open
/// is controlled by the app, so new and imported items are never hidden.
struct LibraryRows<Row: View>: View {
    let nodes: [LibraryNode]
    @Binding var expanded: Set<String>
    let row: (LibraryNode) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: isExpanded(node)) {
                    LibraryRows(nodes: children, expanded: $expanded, row: row)
                } label: {
                    row(node)
                }
            } else {
                row(node)
            }
        }
    }

    private func isExpanded(_ node: LibraryNode) -> Binding<Bool> {
        Binding(get: { expanded.contains(node.id) },
                set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } })
    }
}

struct FolderStyleEditor: View {
    let node: LibraryNode
    let onDone: (FolderStyle) -> Void
    @State private var style: FolderStyle
    @Environment(\.dismiss) private var dismiss

    init(node: LibraryNode, onDone: @escaping (FolderStyle) -> Void) {
        self.node = node
        self.onDone = onDone
        _style = State(initialValue: node.style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: style.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(style.folderColor.color)
                    .frame(width: 44, height: 44)
                Text(node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                ForEach(FolderColor.allCases) { color in
                    Button {
                        style.color = color.rawValue
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.6), lineWidth: style.folderColor == color ? 2 : 0)
                                    .padding(-4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 9), spacing: 6) {
                ForEach(FolderStyle.icons, id: \.self) { icon in
                    Button {
                        style.icon = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(style.icon == icon ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(style.icon == icon ? style.folderColor.color : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Готово") {
                    onDone(style)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
