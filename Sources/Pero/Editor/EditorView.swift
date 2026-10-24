import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsPenSettings = false

    var body: some View {
        Group {
            if let session = model.session {
                PDFCanvas(session: session,
                          isPenEnabled: model.isPenEnabled,
                          penWidth: model.penWidth,
                          penColor: NSColor(hex: model.penColor) ?? .black,
                          onStroke: { page, points in model.addStroke(on: page, points: points) },
                          onAppear: { model.canvas = $0 })
            } else {
                EmptyEditorView()
            }
        }
        .navigationTitle(model.session?.displayName ?? "Перо")
        .navigationSubtitle(model.session == nil ? "" : (model.hasUnsavedInk ? "Сохраняется…" : "Всё сохранено"))
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, into: nil)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Инструмент", selection: $model.isPenEnabled) {
                    Image(systemName: "pencil.tip").tag(true).help("Перо: писать и рисовать")
                    Image(systemName: "cursorarrow").tag(false).help("Курсор: выделять текст и переходить по ссылкам")
                }
                .pickerStyle(.segmented)
                .disabled(model.session == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsPenSettings.toggle()
                } label: {
                    Label("Толщина линии", systemImage: "lineweight")
                }
                .help("Толщина и цвет линии")
                .popover(isPresented: $showsPenSettings, arrowEdge: .bottom) {
                    PenSettingsView()
                        .environmentObject(model)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.undo()
                } label: {
                    Label("Назад", systemImage: "arrow.uturn.backward")
                }
                .help("Убрать последний штрих (⌘Z)")
                .disabled(!model.canUndo)

                Button {
                    model.redo()
                } label: {
                    Label("Вперёд", systemImage: "arrow.uturn.forward")
                }
                .help("Вернуть штрих (⇧⌘Z)")
                .disabled(!model.canRedo)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.exportCurrentDocument()
                } label: {
                    Label("Экспорт PDF", systemImage: "square.and.arrow.up")
                }
                .help("Сохранить PDF с записями (⌘E)")
                .disabled(model.session == nil)
            }
        }
    }
}

struct PenSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Толщина линии")
                .font(.headline)
            HStack(spacing: 12) {
                Slider(value: $model.penWidth, in: 0.5...12)
                Text(String(format: "%.1f", model.penWidth))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            Capsule()
                .fill(Color(nsColor: NSColor(hex: model.penColor) ?? .black))
                .frame(height: max(1, model.penWidth * 1.5))
                .frame(height: 20)
            Divider()
            Text("Цвет")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(AppModel.penColors, id: \.self) { hex in
                    Button {
                        model.penColor = hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .black))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: model.penColor == hex ? 2.5 : 0)
                                    .padding(-4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(16)
        .frame(width: 250)
    }
}

struct EmptyEditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Выберите файл слева или перетащите его сюда")
                .font(.title3)
            Text("PDF, Word, RTF, текст и картинки")
                .foregroundStyle(.secondary)
            Button("Импортировать…") { model.presentImportPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
