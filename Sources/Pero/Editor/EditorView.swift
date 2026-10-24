import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsPalette = false
    @State private var showsBrushes = false

    var body: some View {
        Group {
            if let session = model.session {
                PDFCanvas(session: session,
                          isPenEnabled: model.isPenEnabled,
                          singlePage: model.singlePageMode,
                          brush: model.brush,
                          penWidth: model.penWidth,
                          penColor: NSColor(hex: model.penColor) ?? .black,
                          onStroke: { page, points, id in model.addStroke(on: page, points: points, id: id) },
                          onEraseBegan: { model.beginErasing() },
                          onErase: { page, from, to, radius in model.erase(on: page, from: from, to: to, radius: radius) },
                          onEraseEnded: { model.endErasing() },
                          onPageChanged: { index, count in model.pageChanged(to: index, of: count) },
                          onAppear: { model.canvas = $0 })
                    .overlay(alignment: .trailing) {
                        if model.pageCount > 1 {
                            PageNavigator()
                                .padding(.trailing, 16)
                        }
                    }
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
                Picker("Режим", selection: $model.isPenEnabled) {
                    Image(systemName: "pencil.tip").tag(true)
                        .help("Рисовать (⌘D)")
                    Image(systemName: "cursorarrow").tag(false)
                        .help("Курсор: выделять текст и переходить по ссылкам (⌘D)")
                }
                .pickerStyle(.segmented)
                .disabled(model.session == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsPalette.toggle()
                } label: {
                    Label {
                        Text("Цвет")
                    } icon: {
                        Image(nsImage: colorSwatch(model.penColor))
                    }
                }
                .help("Цвет линии")
                .popover(isPresented: $showsPalette, arrowEdge: .bottom) {
                    PaletteView()
                        .environmentObject(model)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsBrushes.toggle()
                } label: {
                    Label("Инструмент: \(model.brush.name)", systemImage: model.brush.symbol)
                }
                .help("Инструмент и толщина: \(model.brush.name)")
                .popover(isPresented: $showsBrushes, arrowEdge: .bottom) {
                    BrushPickerView()
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
                Picker("Вид", selection: $model.singlePageMode) {
                    Image(systemName: "scroll").tag(false)
                        .help("Лентой: все страницы подряд (⌘1)")
                    Image(systemName: "book.pages").tag(true)
                        .help("По страницам: одна страница за раз (⌘2)")
                }
                .pickerStyle(.segmented)
                .disabled(model.session == nil)
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
