import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Выгрузка") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Копирует всю библиотеку на рабочий стол: все папки и подпапки с их названиями, а внутри — PDF с вашими записями.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Выгрузить всю библиотеку на рабочий стол") { model.exportLibraryToDesktop() }
                            .disabled(model.isExportingLibrary)
                        if model.isExportingLibrary {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Сохранение") {
                Text("Записи сохраняются сами каждые 5 секунд, а также при переключении файла, сворачивании и выходе из приложения. Кнопка «Назад» убирает последний штрих — всё, что нарисовано, не отрывая пера.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            Section("Библиотека") {
                LabeledContent("Где хранится") {
                    Text(model.library.rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("Показать в Finder") { model.revealLibraryInFinder() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
