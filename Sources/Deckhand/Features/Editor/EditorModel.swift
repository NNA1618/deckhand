import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    private struct Snapshot {
        let base: CGImage
        let annotations: [Annotation]
    }

    @Published private(set) var base: CGImage
    @Published var annotations: [Annotation] = []
    @Published var draft: Annotation?
    @Published var cropRect: CGRect?
    @Published var tool: EditorTool = .arrow
    @Published var color: Color = Color(red: 1.0, green: 0.27, blue: 0.23)
    @Published var widthLevel: Int = 1
    @Published var pendingTextPoint: CGPoint?
    @Published var pendingText = ""
    @Published var status: String?

    /// Pixels per point of the source image: 2 for Retina screenshots.
    let pixelScale: CGFloat
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    static let palette: [Color] = [
        Color(red: 1.0, green: 0.27, blue: 0.23),
        Color(red: 1.0, green: 0.62, blue: 0.04),
        Color(red: 1.0, green: 0.84, blue: 0.04),
        Color(red: 0.19, green: 0.82, blue: 0.35),
        Color(red: 0.04, green: 0.52, blue: 1.0),
        Color(red: 0.75, green: 0.35, blue: 0.95),
        .white,
        .black,
    ]

    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        base = cg
        pixelScale = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
    }

    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Stroke width in image pixels: 3, 6 or 10 points.
    var strokeWidth: CGFloat { [3, 6, 10][widthLevel] * pixelScale }

    // MARK: - History

    private func pushUndo() {
        undoStack.append(Snapshot(base: base, annotations: annotations))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, annotations: annotations))
        base = last.base
        annotations = last.annotations
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, annotations: annotations))
        base = next.base
        annotations = next.annotations
    }

    // MARK: - Gestures (coordinates are already in image pixels)

    func dragChanged(start: CGPoint, current: CGPoint) {
        let a = clamp(start), b = clamp(current)
        switch tool {
        case .pen, .marker:
            if case .pen(var pts)? = draft?.kind {
                pts.append(b); draft?.kind = .pen(pts)
            } else if case .marker(var pts)? = draft?.kind {
                pts.append(b); draft?.kind = .marker(pts)
            } else {
                draft = Annotation(kind: tool == .pen ? .pen([a, b]) : .marker([a, b]), color: color, width: strokeWidth)
            }
        case .rect: draft = Annotation(kind: .rect(a, b), color: color, width: strokeWidth)
        case .ellipse: draft = Annotation(kind: .ellipse(a, b), color: color, width: strokeWidth)
        case .line: draft = Annotation(kind: .line(a, b), color: color, width: strokeWidth)
        case .arrow: draft = Annotation(kind: .arrow(a, b), color: color, width: strokeWidth)
        case .crop:
            cropRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .text:
            break
        }
    }

    func dragEnded(start: CGPoint, end: CGPoint) {
        if tool == .text {
            commitText()
            pendingTextPoint = clamp(end)
            pendingText = ""
            return
        }
        guard let d = draft else { return }
        draft = nil
        let moved = hypot(end.x - start.x, end.y - start.y)
        let isStroke: Bool = { if case .pen = d.kind { return true }; if case .marker = d.kind { return true }; return false }()
        guard moved > 3 || isStroke else { return }
        pushUndo()
        annotations.append(d)
    }

    func commitText() {
        defer { pendingTextPoint = nil; pendingText = "" }
        guard let at = pendingTextPoint, !pendingText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        pushUndo()
        annotations.append(Annotation(kind: .text(at, pendingText), color: color, width: strokeWidth))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(base.width)), y: min(max(p.y, 0), CGFloat(base.height)))
    }

    // MARK: - Crop

    func applyCrop() {
        guard let rect = cropRect?.integral, rect.width > 4, rect.height > 4,
              let flat = renderCGImage(),
              let cropped = flat.cropping(to: rect) else { return }
        pushUndo()
        base = cropped
        annotations = []
        cropRect = nil
        tool = .arrow
    }

    func cancelCrop() { cropRect = nil }

    // MARK: - Export

    func renderCGImage() -> CGImage? {
        let size = imageSize
        let base = self.base
        let items = annotations
        let view = Canvas { ctx, _ in
            ctx.draw(Image(decorative: base, scale: 1), in: CGRect(origin: .zero, size: size))
            for a in items { a.draw(in: &ctx, scale: 1) }
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage
    }

    func renderNSImage() -> NSImage? {
        guard let cg = renderCGImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / pixelScale,
                                                  height: CGFloat(cg.height) / pixelScale))
    }

    func copyToClipboard() {
        commitText()
        guard let image = renderNSImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash(String(localized: "Copied"))
    }

    func save() {
        commitText()
        guard let cg = renderCGImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = String(localized: "Screenshot") + " \(stamp.string(from: Date())).png"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            flash(String(localized: "Saved"))
        }
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.status == text { self?.status = nil }
        }
    }
}
