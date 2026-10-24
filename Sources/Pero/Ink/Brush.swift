import AppKit

/// Drawing tools. Every stroke remembers its brush, so it looks the same while it is
/// being drawn, on the page and in the exported PDF.
enum Brush: String, CaseIterable, Identifiable {
    case pen, pencil, dashed, fountainPen, brush, marker, highlighter, crayon, watercolor, eraser

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pen: return "Ручка"
        case .pencil: return "Карандаш"
        case .dashed: return "Пунктир"
        case .fountainPen: return "Перо"
        case .brush: return "Кисть"
        case .marker: return "Маркер"
        case .highlighter: return "Выделитель"
        case .crayon: return "Мелок"
        case .watercolor: return "Акварель"
        case .eraser: return "Ластик"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .dashed: return "line.diagonal"
        case .fountainPen: return "signature"
        case .brush: return "paintbrush.pointed"
        case .marker: return "scribble.variable"
        case .highlighter: return "highlighter"
        case .crayon: return "scribble"
        case .watercolor: return "drop"
        case .eraser: return "eraser"
        }
    }

    /// Line width in PDF points (for the eraser: its diameter).
    var defaultWidth: Double {
        switch self {
        case .pen: return 1.5
        case .pencil: return 1.6
        case .dashed: return 1.5
        case .fountainPen: return 3
        case .brush: return 4
        case .marker: return 5
        case .highlighter: return 14
        case .crayon: return 5
        case .watercolor: return 12
        case .eraser: return 12
        }
    }

    var widthRange: ClosedRange<Double> {
        switch self {
        case .pen, .dashed: return 0.5...10
        case .pencil: return 0.5...8
        case .fountainPen: return 1...12
        case .brush: return 1...24
        case .marker: return 2...20
        case .highlighter: return 6...40
        case .crayon: return 2...20
        case .watercolor: return 4...40
        case .eraser: return 4...60
        }
    }
}

/// Draws a stroke with its brush. Everything scales with the width, so a stroke
/// drawn on screen at any zoom and the same stroke on the page look identical.
enum InkRenderer {
    static func draw(_ points: [CGPoint], width: CGFloat, color: NSColor, brush: Brush, seed: UInt64, in context: CGContext) {
        guard !points.isEmpty, width > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if points.count == 1 && (brush == .pencil || brush == .crayon) {
            // Grain has no room in a tap; a soft dot instead.
            return dot(points[0], diameter: width * 0.9, color: color.withAlphaComponent(0.7), in: context)
        }
        switch brush {
        case .pen, .eraser:
            InkPath.stroke(points, width: width, color: color, in: context)
        case .dashed:
            context.setLineDash(phase: 0, lengths: [max(1.4 * width, 2.5), max(2.8 * width, 4)])
            InkPath.stroke(points, width: width, color: color, in: context)
        case .marker:
            strokeLine(InkPath.make(points), width: width, color: color.withAlphaComponent(0.88), cap: .round, in: context)
        case .highlighter:
            strokeLine(InkPath.make(points), width: width, color: color.withAlphaComponent(0.35), cap: .butt, in: context)
        case .pencil:
            pencil(points, width: width, color: color, seed: seed, in: context)
        case .crayon:
            crayon(points, width: width, color: color, seed: seed, in: context)
        case .watercolor:
            watercolor(points, width: width, color: color, seed: seed, in: context)
        case .brush:
            brushStroke(points, width: width, color: color, in: context)
        case .fountainPen:
            fountainPen(points, width: width, color: color, in: context)
        }
    }

    // MARK: - Textured brushes

    private static func pencil(_ points: [CGPoint], width: CGFloat, color: NSColor, seed: UInt64, in context: CGContext) {
        let line = Geometry.smooth(points, step: max(0.3, width * 0.25))
        strokeLine(Geometry.path(line), width: width * 0.7, color: color.withAlphaComponent(0.3), cap: .round, in: context)
        // Graphite grain: ragged broken lines across the width.
        grain(line, lanes: 4, spread: 0.7, jitter: 0.08, laneWidth: 0.28, on: 0.08...0.45, off: 0.05...0.3,
              width: width, color: color.withAlphaComponent(0.75), seed: seed, in: context)
    }

    private static func crayon(_ points: [CGPoint], width: CGFloat, color: NSColor, seed: UInt64, in context: CGContext) {
        let line = Geometry.smooth(points, step: max(0.4, width * 0.2))
        strokeLine(Geometry.path(line), width: width * 0.9, color: color.withAlphaComponent(0.18), cap: .round, in: context)
        // Wax: many short broken lines, leaving paper showing through.
        grain(line, lanes: 9, spread: 0.9, jitter: 0.05, laneWidth: 0.14, on: 0.1...0.9, off: 0.05...0.45,
              width: width, color: color.withAlphaComponent(0.8), seed: seed, in: context)
    }

    /// Thin dashed lanes along the line, each wandering a little, with gaps that never repeat.
    /// Each lane draws from its own generator, and the gaps come before the wander, so
    /// the grain already drawn stays put while the stroke grows.
    private static func grain(_ line: [CGPoint], lanes: Int, spread: CGFloat, jitter: CGFloat, laneWidth: CGFloat,
                              on: ClosedRange<CGFloat>, off: ClosedRange<CGFloat>, width: CGFloat, color: NSColor,
                              seed: UInt64, in context: CGContext) {
        for k in 0..<lanes {
            var random = SplitMix(seed &+ UInt64(k + 1) &* 0x2545_F491_4F6C_DD1D)
            let phase = random.next(0, width)
            let pattern = dashes(&random, on: on, off: off, width: width)
            let offset = (CGFloat(k) / CGFloat(max(lanes - 1, 1)) - 0.5) * width * spread
            let wander = Geometry.noise(count: line.count, every: 6, amplitude: jitter * width, random: &random)
            let lane = Geometry.offset(line, by: { offset + wander[$0] })
            context.setLineDash(phase: phase, lengths: pattern)
            strokeLine(Geometry.path(lane), width: width * laneWidth, color: color, cap: .butt, in: context)
        }
    }

    private static func watercolor(_ points: [CGPoint], width: CGFloat, color: NSColor, seed: UInt64, in context: CGContext) {
        let line = Geometry.smooth(points, step: max(0.5, width * 0.2))
        // Layers of thin paint: darker in the middle, soft at the sides.
        for (k, (scale, alpha)) in ([(1.0, 0.15), (0.8, 0.13), (0.55, 0.13), (0.3, 0.1)] as [(CGFloat, CGFloat)]).enumerated() {
            var random = SplitMix(seed &+ UInt64(k + 1) &* 0x2545_F491_4F6C_DD1D)
            let wander = Geometry.noise(count: line.count, every: 10, amplitude: 0.04 * width, random: &random)
            let layer = Geometry.offset(line, by: { wander[$0] })
            strokeLine(Geometry.path(layer), width: width * scale, color: color.withAlphaComponent(alpha), cap: .round, in: context)
        }
    }

    // MARK: - Brushes with changing width

    /// Thick when slow, thin when fast, pointed at both ends.
    private static func brushStroke(_ points: [CGPoint], width: CGFloat, color: NSColor, in context: CGContext) {
        let speeds = Geometry.speeds(points, smoothing: 3)
        let line = Geometry.smooth(points, values: speeds, step: max(0.4, width * 0.18))
        let lengths = Geometry.lengths(line.points)
        let total = lengths.last ?? 0
        // A tap leaves a round dab.
        guard total > width * 0.8 else { return dot(points[0], diameter: width * 1.1, color: color, in: context) }
        // Short strokes taper over a proportionally shorter distance.
        let startTaper = min(2.5 * width, total * 0.3), endTaper = min(5 * width, total * 0.45)
        let widths = line.points.indices.map { i -> CGFloat in
            let speed = line.values[i] / width
            let pressure = min(max(1.25 - 0.09 * speed, 0.45), 1.25)
            let d = lengths[i]
            let taper = pow(min(1, d / startTaper), 0.6) * pow(min(1, (total - d) / endTaper), 0.7)
            return width * pressure * max(taper, 0.12)
        }
        fill(Geometry.ribbon(line.points, widths: widths), color: color, in: context)
    }

    /// A nib held at 40°: thin along the nib, wide across it.
    private static func fountainPen(_ points: [CGPoint], width: CGFloat, color: NSColor, in context: CGContext) {
        let line = Geometry.smooth(points, step: max(0.3, width * 0.15)).points
        let lengths = Geometry.lengths(line)
        let total = lengths.last ?? 0
        guard total > width * 0.6 else { return dot(points[0], diameter: width * 0.8, color: color, in: context) }
        let nib: CGFloat = 40 * .pi / 180
        let widths = line.indices.map { i -> CGFloat in
            let a = line[max(i - 1, 0)], b = line[min(i + 1, line.count - 1)]
            let angle = atan2(b.y - a.y, b.x - a.x)
            let across = abs(sin(angle - nib))
            let d = lengths[i]
            let taper = min(1, d / (1.2 * width)) * min(1, (total - d) / (1.2 * width))
            return width * (0.22 + 0.9 * across) * max(taper, 0.35)
        }
        fill(Geometry.ribbon(line, widths: widths), color: color, in: context)
    }

    // MARK: - Helpers

    private static func strokeLine(_ path: CGPath, width: CGFloat, color: NSColor, cap: CGLineCap, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(cap)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func dot(_ center: CGPoint, diameter: CGFloat, color: NSColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
    }

    private static func fill(_ path: CGPath, color: NSColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath(using: .winding)
    }

    private static func dashes(_ random: inout SplitMix, on: ClosedRange<CGFloat>, off: ClosedRange<CGFloat>, width: CGFloat) -> [CGFloat] {
        (0..<24).flatMap { _ in [random.next(on.lowerBound, on.upperBound) * width, random.next(off.lowerBound, off.upperBound) * width] }
    }
}

/// Polylines for the renderer.
enum Geometry {
    struct Line {
        var points: [CGPoint]
        var values: [CGFloat]
    }

    /// Dense points along the same smooth curve as InkPath.make, carrying a value per point.
    static func smooth(_ points: [CGPoint], values: [CGFloat]? = nil, step: CGFloat) -> Line {
        let values = values ?? Array(repeating: 0, count: points.count)
        guard points.count > 2 else { return Line(points: points, values: values) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var out = Line(points: [points[0]], values: [values[0]])
        var from = points[0], fromValue = values[0]
        for i in 1..<(points.count - 1) {
            let control = points[i]
            let to = mid(points[i], points[i + 1])
            let toValue = (values[i] + values[i + 1]) / 2
            let length = hypot(control.x - from.x, control.y - from.y) + hypot(to.x - control.x, to.y - control.y)
            let n = max(1, min(64, Int(length / step)))
            for k in 1...n {
                let t = CGFloat(k) / CGFloat(n), u = 1 - t
                out.points.append(CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                          y: u * u * from.y + 2 * u * t * control.y + t * t * to.y))
                out.values.append(u * u * fromValue + 2 * u * t * values[i] + t * t * toValue)
            }
            from = to
            fromValue = toValue
        }
        out.points.append(points[points.count - 1])
        out.values.append(values[values.count - 1])
        return out
    }

    static func smooth(_ points: [CGPoint], step: CGFloat) -> [CGPoint] {
        smooth(points, values: nil, step: step).points
    }

    /// Distance to the previous point, averaged over neighbours: how fast the pen moved.
    static func speeds(_ points: [CGPoint], smoothing: Int) -> [CGFloat] {
        guard points.count > 1 else { return Array(repeating: 0, count: points.count) }
        let raw = points.indices.map { i -> CGFloat in
            let a = points[max(i - 1, 0)], b = points[i == 0 ? 1 : i]
            return hypot(b.x - a.x, b.y - a.y)
        }
        return raw.indices.map { i in
            let range = max(0, i - smoothing)...min(raw.count - 1, i + smoothing)
            return raw[range].reduce(0, +) / CGFloat(range.count)
        }
    }

    /// Distance along the line from its start, per point.
    static func lengths(_ points: [CGPoint]) -> [CGFloat] {
        var total: CGFloat = 0
        return points.indices.map { i in
            if i > 0 { total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
            return total
        }
    }

    /// Smooth random values: random every `every` points, linear in between.
    static func noise(count: Int, every: Int, amplitude: CGFloat, random: inout SplitMix) -> [CGFloat] {
        guard count > 0 else { return [] }
        let knots = (0...(count / every + 1)).map { _ in random.next(-amplitude, amplitude) }
        return (0..<count).map { i in
            let k = i / every, t = CGFloat(i % every) / CGFloat(every)
            return knots[k] * (1 - t) + knots[k + 1] * t
        }
    }

    /// The line moved sideways (along its normal) by `offset(i)` at each point.
    static func offset(_ points: [CGPoint], by offset: (Int) -> CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return points }
        return points.indices.map { i in
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(hypot(dx, dy), 0.0001)
            let o = offset(i)
            return CGPoint(x: points[i].x - dy / length * o, y: points[i].y + dx / length * o)
        }
    }

    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        } else {
            path.addLines(between: points)
        }
        return path
    }

    /// Outline of a line whose width changes along it: a disc at every point joined
    /// by quads, all wound the same way so one fill covers the union.
    static func ribbon(_ points: [CGPoint], widths: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        for i in points.indices {
            let r = widths[i] / 2
            guard r > 0.005 else { continue }
            path.move(to: CGPoint(x: points[i].x + r, y: points[i].y))
            path.addArc(center: points[i], radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            guard i > 0 else { continue }
            let a = points[i - 1], b = points[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length > 0.0001 else { continue }
            let nx = -dy / length, ny = dx / length
            let r0 = widths[i - 1] / 2
            var quad = [CGPoint(x: a.x + nx * r0, y: a.y + ny * r0), CGPoint(x: b.x + nx * r, y: b.y + ny * r),
                        CGPoint(x: b.x - nx * r, y: b.y - ny * r), CGPoint(x: a.x - nx * r0, y: a.y - ny * r0)]
            if signedArea(quad) < 0 { quad.reverse() }
            path.addLines(between: quad)
            path.closeSubpath()
        }
        return path
    }

    private static func signedArea(_ p: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in p.indices {
            let j = (i + 1) % p.count
            area += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return area / 2
    }
}

/// Small deterministic random generator: the same stroke always gets the same texture.
struct SplitMix {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low + (high - low) * CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
