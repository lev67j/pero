import AppKit

/// One continuous pen movement: from touching the page to lifting the pen.
struct InkStroke: Codable, Identifiable, Equatable {
    var id: UUID
    /// Index of the PDF page the stroke was drawn on.
    var page: Int
    /// "#RRGGBB".
    var color: String
    /// Line width in PDF page points.
    var width: Double
    /// Flattened page coordinates: x0, y0, x1, y1, ...
    var points: [Double]

    init(id: UUID = UUID(), page: Int, color: String, width: Double, points: [CGPoint]) {
        self.id = id
        self.page = page
        self.color = color
        self.width = width
        self.points = points.flatMap { [Self.round($0.x), Self.round($0.y)] }
    }

    var cgPoints: [CGPoint] {
        stride(from: 0, to: points.count - 1, by: 2).map { CGPoint(x: points[$0], y: points[$0 + 1]) }
    }

    var nsColor: NSColor { NSColor(hex: color) ?? .black }

    var bounds: CGRect {
        let pts = cgPoints
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = width / 2 + 2
        return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
    }

    private static func round(_ v: CGFloat) -> Double {
        (Double(v) * 100).rounded() / 100
    }
}

/// Contents of `ink.json` inside a document package.
struct InkFile: Codable {
    var version: Int = 1
    var strokes: [InkStroke]
}

enum InkPath {
    /// Smooth path through the points (quadratic curves through midpoints).
    static func make(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            // A tiny segment so round caps draw a dot.
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func stroke(_ points: [CGPoint], width: CGFloat, color: NSColor, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(make(points))
        context.strokePath()
        context.restoreGState()
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
