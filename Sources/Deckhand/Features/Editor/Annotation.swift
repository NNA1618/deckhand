import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case pen, marker, rect, ellipse, line, arrow, text, crop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return String(localized: "Pen")
        case .marker: return String(localized: "Highlighter")
        case .rect: return String(localized: "Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .line: return String(localized: "Line")
        case .arrow: return String(localized: "Arrow")
        case .text: return String(localized: "Text")
        case .crop: return String(localized: "Crop")
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .crop: return "crop"
        }
    }
    var shortcut: KeyEquivalent {
        switch self {
        case .pen: return "p"
        case .marker: return "m"
        case .rect: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .arrow: return "a"
        case .text: return "t"
        case .crop: return "c"
        }
    }
}

/// One annotation. Coordinates and widths are in source image pixels,
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
    }

    let id = UUID()
    var kind: Kind
    var color: Color
    var width: CGFloat

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
        case .text(let at, let string):
            let size = width * 6 * s
            let text = Text(string)
                .font(.system(size: size, weight: .bold))
                .foregroundColor(color)
            ctx.draw(text, at: p(at), anchor: .topLeading)
        }
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
