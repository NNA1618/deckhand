import SwiftUI
import AppKit
import Carbon.HIToolbox

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, pen, marker, text, blur, redact, crop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return String(localized: "Select and Move")
        case .pen: return String(localized: "Pen")
        case .marker: return String(localized: "Highlighter")
        case .rect: return String(localized: "Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .line: return String(localized: "Line")
        case .arrow: return String(localized: "Arrow")
        case .text: return String(localized: "Text")
        case .blur: return String(localized: "Blur")
        case .redact: return String(localized: "Redact")
        case .crop: return String(localized: "Crop")
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .blur: return "checkerboard.rectangle"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
    /// The physical key that picks the tool, so it works with any layout (the Russian «с» is the C key).
    var keyCode: Int {
        switch self {
        case .select: return kVK_ANSI_V
        case .pen: return kVK_ANSI_P
        case .marker: return kVK_ANSI_M
        case .rect: return kVK_ANSI_R
        case .ellipse: return kVK_ANSI_O
        case .line: return kVK_ANSI_L
        case .arrow: return kVK_ANSI_A
        case .text: return kVK_ANSI_T
        case .blur: return kVK_ANSI_B
        case .redact: return kVK_ANSI_X
        case .crop: return kVK_ANSI_C
        }
    }
    /// Tools that draw something and use the color and width.
    var usesColor: Bool { ![.select, .blur, .redact, .crop].contains(self) }
}

/// One annotation. Coordinates and sizes are in source image pixels,
/// so the export matches what is shown on screen.
struct Annotation: Identifiable {
    enum Kind {
        case pen([CGPoint])
        case marker([CGPoint])
        case rect(CGPoint, CGPoint)
        case ellipse(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)
        case text(CGPoint, String)
        /// Hides a region by pixelating and blurring it. The pixels come from EditorModel; here only the outline.
        case pixelate(CGPoint, CGPoint)
        /// Covers a region with a solid black box.
        case redact(CGPoint, CGPoint)
    }

    let id = UUID()
    var kind: Kind
    var color: Color
    var width: CGFloat
    /// Text height in image pixels; only for text.
    var fontSize: CGFloat = 0

    /// Draws the annotation. `scale` maps image pixels to canvas points.
    func draw(in ctx: inout GraphicsContext, scale s: CGFloat) {
        let w = width * s
        let stroke = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        func p(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x * s, y: pt.y * s) }
        func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x) * s, y: min(a.y, b.y) * s,
                   width: abs(a.x - b.x) * s, height: abs(a.y - b.y) * s)
        }

        switch kind {
        case .pen(let pts):
            ctx.stroke(Self.smoothPath(pts.map(p)), with: .color(color), style: stroke)
        case .marker(let pts):
            ctx.stroke(Self.smoothPath(pts.map(p)), with: .color(color.opacity(0.38)),
                       style: StrokeStyle(lineWidth: w * 4, lineCap: .square, lineJoin: .round))
        case .rect(let a, let b):
            ctx.stroke(Path(roundedRect: box(a, b), cornerRadius: w), with: .color(color), style: stroke)
        case .ellipse(let a, let b):
            ctx.stroke(Path(ellipseIn: box(a, b)), with: .color(color), style: stroke)
        case .line(let a, let b):
            var path = Path()
            path.move(to: p(a)); path.addLine(to: p(b))
            ctx.stroke(path, with: .color(color), style: stroke)
        case .arrow(let a, let b):
            let start = p(a), end = p(b)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = max(w * 4, 14 * s)
            let spread: CGFloat = .pi / 7
            let left = CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread))
            let right = CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread))
            // the shaft stops at the base of the head so the tip stays sharp
            let base = CGPoint(x: end.x - head * 0.8 * cos(angle), y: end.y - head * 0.8 * sin(angle))
            var shaft = Path()
            shaft.move(to: start); shaft.addLine(to: base)
            ctx.stroke(shaft, with: .color(color), style: stroke)
            var tip = Path()
            tip.move(to: end); tip.addLine(to: left); tip.addLine(to: right); tip.closeSubpath()
            ctx.fill(tip, with: .color(color))
            ctx.stroke(tip, with: .color(color), style: StrokeStyle(lineWidth: w * 0.6, lineJoin: .round))
        case .pixelate(let a, let b):
            ctx.stroke(Path(box(a, b)), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        case .redact(let a, let b):
            ctx.fill(Path(box(a, b)), with: .color(.black))
        case .text(let at, let string):
            let size = fontSize * s
            let text = Text(verbatim: string)
                .font(.system(size: size, weight: .bold))
                .foregroundColor(color)
            // A soft contrasting halo keeps text readable on any background
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: Self.halo(for: color), radius: max(1, size * 0.08)))
                layer.draw(text, at: p(at), anchor: .topLeading)
            }
        }
    }

    private static func halo(for color: Color) -> Color {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma > 0.6 ? .black.opacity(0.55) : .white.opacity(0.55)
    }

    static func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            if pts.count == 1 { path.addLine(to: first) }
            return path
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

extension Annotation {
    /// The region of a blur annotation, in image pixels.
    var pixelateRect: CGRect? {
        guard case .pixelate(let a, let b) = kind else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The area the annotation covers, in image pixels, for selecting and moving.
    var bounds: CGRect {
        func box(_ pts: [CGPoint]) -> CGRect {
            guard let first = pts.first else { return .null }
            return pts.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let pad = width / 2
        switch kind {
        case .pen(let pts): return box(pts).insetBy(dx: -pad, dy: -pad)
        case .marker(let pts): return box(pts).insetBy(dx: -pad * 4, dy: -pad * 4)
        case .rect(let a, let b), .ellipse(let a, let b), .line(let a, let b), .arrow(let a, let b):
            return box([a, b]).insetBy(dx: -pad, dy: -pad)
        case .pixelate(let a, let b), .redact(let a, let b):
            return box([a, b])
        case .text(let at, let string):
            let size = (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold)])
            return CGRect(origin: at, size: size)
        }
    }

    /// Whether a click at `point` picks this annotation. Thin shapes get a margin so they are easy to hit.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    func offset(by d: CGSize) -> Annotation {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
        var copy = self
        switch kind {
        case .pen(let pts): copy.kind = .pen(pts.map(m))
        case .marker(let pts): copy.kind = .marker(pts.map(m))
        case .rect(let a, let b): copy.kind = .rect(m(a), m(b))
        case .ellipse(let a, let b): copy.kind = .ellipse(m(a), m(b))
        case .line(let a, let b): copy.kind = .line(m(a), m(b))
        case .arrow(let a, let b): copy.kind = .arrow(m(a), m(b))
        case .text(let at, let s): copy.kind = .text(m(at), s)
        case .pixelate(let a, let b): copy.kind = .pixelate(m(a), m(b))
        case .redact(let a, let b): copy.kind = .redact(m(a), m(b))
        }
        return copy
    }
}
