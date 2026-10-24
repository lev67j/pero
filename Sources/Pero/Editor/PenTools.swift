import AppKit
import SwiftUI

enum InkTool: Hashable {
    /// Graphics tablet pen or mouse: draws while pressed.
    case pen
    /// Finger on the trackpad, which works like a small tablet.
    case trackpad
    /// Select text and follow links.
    case cursor
}

struct PenColor: Hashable {
    let hex: String
    let name: String

    init(_ hex: String, _ name: String) {
        self.hex = hex
        self.name = name
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Routes the shared NSColorPanel to the pen color. The panel outlives the
/// popover that opened it, so it can't talk to a SwiftUI view directly.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(with color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.color = color
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

/// A filled circle as a non-template image, so the toolbar shows the real color.
func colorSwatch(_ hex: String, size: CGFloat = 16) -> NSImage {
    let color = NSColor(hex: hex) ?? .black
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        return true
    }
    image.isTemplate = false
    return image
}

struct ColorDot: View {
    let hex: String
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(nsColor: NSColor(hex: hex) ?? .black))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            .frame(width: 20, height: 20)
            .overlay(
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
                    .padding(-4)
            )
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
}

/// Apple's colors, the user's saved colors and the system color panel.
struct PaletteView: View {
    @EnvironmentObject private var model: AppModel
    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 4), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Цвет")
                .font(.headline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(AppModel.penColors, id: \.self) { color in
                    Button {
                        model.penColor = color.hex
                    } label: {
                        ColorDot(hex: color.hex, isSelected: model.penColor.uppercased() == color.hex)
                    }
                    .buttonStyle(.plain)
                    .help(color.name)
                }
            }

            Divider()

            HStack {
                Text("Мои цвета")
                    .font(.headline)
                Spacer()
                Button {
                    model.saveCurrentColor()
                } label: {
                    Label("Сохранить текущий", systemImage: "plus")
                }
                .disabled(model.isCurrentColorSaved)
                .help("Добавить текущий цвет в «Мои цвета»")
            }
            if model.customPenColors.isEmpty {
                Text("Выберите цвет в палитре и нажмите «Сохранить текущий».")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(model.customPenColors, id: \.self) { hex in
                        Button {
                            model.penColor = hex
                        } label: {
                            ColorDot(hex: hex, isSelected: model.penColor.uppercased() == hex)
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                        .contextMenu {
                            Button("Убрать из «Моих цветов»", role: .destructive) { model.removeCustomColor(hex) }
                        }
                    }
                }
            }

            Button {
                model.openColorPanel()
            } label: {
                Label("Палитра цветов…", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 300)
    }
}

struct PenWidthView: View {
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
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(height: max(1, model.penWidth * 1.5))
                .frame(height: 20)
        }
        .padding(16)
        .frame(width: 250)
    }
}

/// Floating page switcher on the right edge of the document.
struct PageNavigator: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 2) {
            Button {
                model.previousPage()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(model.currentPage == 0)
            .help("Предыдущая страница (⌥⌘↑)")

            VStack(spacing: 0) {
                Text("\(model.currentPage + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Text("из \(model.pageCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 36)

            Button {
                model.nextPage()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(model.currentPage >= model.pageCount - 1)
            .help("Следующая страница (⌥⌘↓)")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// Shown on top of the page while the finger tool is on.
struct TrackpadHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.point.up.left")
            Text("Пишите пальцем по трекпаду · два пальца — прокрутка · Esc — выйти")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
