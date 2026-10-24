// Draws the app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(in ctx: CGContext) {
    // Rounded square on the standard macOS icon grid.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.33, green: 0.56, blue: 1.0, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.10, green: 0.29, blue: 0.80, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Sheet of paper.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -0.08)
    let sheet = CGRect(x: -235, y: -300, width: 470, height: 600)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Printed lines.
    ctx.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor)
    for i in 0..<5 {
        let y = 190 - CGFloat(i) * 62
        let width: CGFloat = i == 4 ? 220 : 370
        ctx.addPath(CGPath(roundedRect: CGRect(x: -185, y: y, width: width, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
    }

    // Handwritten stroke over the page.
    let ink = CGMutablePath()
    ink.move(to: CGPoint(x: -190, y: -150))
    ink.addCurve(to: CGPoint(x: -90, y: -120), control1: CGPoint(x: -170, y: -60), control2: CGPoint(x: -120, y: -60))
    ink.addCurve(to: CGPoint(x: 10, y: -150), control1: CGPoint(x: -60, y: -190), control2: CGPoint(x: -20, y: -210))
    ink.addCurve(to: CGPoint(x: 100, y: -110), control1: CGPoint(x: 40, y: -90), control2: CGPoint(x: 70, y: -70))
    ink.addCurve(to: CGPoint(x: 190, y: -170), control1: CGPoint(x: 130, y: -150), control2: CGPoint(x: 160, y: -200))
    ctx.addPath(ink)
    ctx.setStrokeColor(NSColor(srgbRed: 0.08, green: 0.22, blue: 0.62, alpha: 1).cgColor)
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent("\(name).png"))
}
