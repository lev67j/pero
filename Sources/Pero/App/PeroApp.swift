import SwiftUI

@main
struct PeroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Перо", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.library)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1200, height: 840)
        .commands { PeroCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

struct ContentView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
        } detail: {
            EditorView()
        }
    }
}

struct PeroCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая папка") { model.createFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Импортировать…") { model.presentImportPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Экспортировать PDF…") { model.exportCurrentDocument() }
                .keyboardShortcut("e")
                .disabled(model.session == nil)
            Divider()
            Button(model.hasExportFolder ? "Обновить папку с выгрузкой" : "Выгрузить библиотеку на рабочий стол") {
                model.exportOrUpdateLibrary()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.isExportingLibrary)
            Button("Выгрузить в новую папку на рабочем столе") { model.exportLibraryToDesktop() }
                .disabled(model.isExportingLibrary)
            Button("Указать папку с выгрузкой…") { model.chooseExportFolder() }
                .disabled(model.isExportingLibrary)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Убрать последний штрих") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Вернуть штрих") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
        CommandGroup(before: .toolbar) {
            Button(model.isPenEnabled ? "Курсор" : "Перо") { model.isPenEnabled.toggle() }
                .keyboardShortcut("d")
                .disabled(model.session == nil)
            Button(model.brush == .eraser ? "Убрать ластик" : "Ластик") {
                model.brush = model.brush == .eraser ? .pen : .eraser
                model.isPenEnabled = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.session == nil)
            Divider()
            Button("Лентой") { model.singlePageMode = false }
                .keyboardShortcut("1")
            Button("По страницам") { model.singlePageMode = true }
                .keyboardShortcut("2")
            Button("Предыдущая страница") { model.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model.session == nil)
            Button("Следующая страница") { model.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.session == nil)
            Divider()
            Button("Увеличить") { model.zoom(by: 1.25) }
                .keyboardShortcut("=")
            Button("Уменьшить") { model.zoom(by: 0.8) }
                .keyboardShortcut("-")
            Button("По ширине страницы") { model.zoomToFit() }
                .keyboardShortcut("0")
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // More points per second from the tablet = smoother lines.
        NSEvent.isMouseCoalescingEnabled = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.importFiles(urls, into: AppModel.shared.library.rootURL)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.saveNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.saveNow() }
    }
}
