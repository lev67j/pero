import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Выгрузка на рабочий стол") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Вся библиотека — одной папкой: те же папки и подпапки с их названиями, внутри — PDF с вашими записями. Потом её можно не выгружать заново, а обновить: допишутся только новые и изменённые файлы.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let folder = model.exportFolder {
                        LabeledContent("Папка") {
                            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        HStack {
                            Button("Обновить папку") { model.updateExport() }
                                .keyboardShortcut(.defaultAction)
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            if model.isExportingLibrary {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .disabled(model.isExportingLibrary)
                    } else if model.hasExportFolder {
                        Text("Папку с выгрузкой не нашли: её могли удалить или перенести на другой диск.")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if !model.hasExportFolder || model.exportFolder == nil {
                            Button("Выгрузить на рабочий стол") { model.exportLibraryToDesktop() }
                        } else {
                            Button("Выгрузить в новую папку") { model.exportLibraryToDesktop() }
                        }
                        Button("Указать папку…") { model.chooseExportFolder() }
                            .help("Если вы переместили или переименовали папку с выгрузкой, или хотите выгружать в другую")
                        if model.isExportingLibrary && model.exportFolder == nil {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .disabled(model.isExportingLibrary)
                }
                .padding(.vertical, 4)
            }
            Section("Сохранение") {
                Text("Записи сохраняются сами каждые 5 секунд, а также при переключении файла, сворачивании и выходе из приложения. «Назад» убирает последний штрих — всё, что нарисовано, не отрывая пера, — или возвращает стёртое ластиком.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            Section("Библиотека") {
                LabeledContent("Где хранится") {
                    Text((model.library.rootURL.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Показать в Finder") { model.revealLibraryInFinder() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
