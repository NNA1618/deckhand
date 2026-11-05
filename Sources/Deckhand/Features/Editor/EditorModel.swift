import SwiftUI
import CoreImage
import AppKit
import Carbon.HIToolbox

/// Keyboard commands of the editor window. Mapped from physical key codes, so they work with any layout.
enum EditorCommand: Equatable {
    case tool(EditorTool)
    case undo, redo, copy, save
    case zoomIn, zoomOut, zoomFit, zoomActual
    /// Return: apply the crop.
    case confirm
    /// Esc: cancel the crop or the selection.
    case cancel
    /// Delete: remove the selected annotation.
    case delete

    /// nil lets the key through: always while a text field has focus, so typing, ⌘C and ⌘Z
    /// in the Ask field or a text annotation behave like in any text field.
    static func from(keyCode: Int, modifiers: UInt32, textFocused: Bool) -> EditorCommand? {
        guard !textFocused else { return nil }
        let cmd = Shortcut.command, shift = Shortcut.shift
        switch modifiers {
        case 0:
            if let tool = EditorTool.allCases.first(where: { $0.keyCode == keyCode }) { return .tool(tool) }
            switch keyCode {
            case kVK_Return, kVK_ANSI_KeypadEnter: return .confirm
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .delete
            default: return nil
            }
        case cmd:
            switch keyCode {
            case kVK_ANSI_Z: return .undo
            case kVK_ANSI_C: return .copy
            case kVK_ANSI_S: return .save
            case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: return .zoomIn
            case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: return .zoomOut
            case kVK_ANSI_0: return .zoomFit
            case kVK_ANSI_1: return .zoomActual
            default: return nil
            }
        case cmd | shift:
            switch keyCode {
            case kVK_ANSI_Z: return .redo
            case kVK_ANSI_Equal: return .zoomIn
            default: return nil
            }
        default:
            return nil
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    private struct Snapshot {
        let base: CGImage
        let annotations: [Annotation]
    }

    @Published private(set) var base: CGImage { didSet { version += 1 } }
    @Published var annotations: [Annotation] = [] { didSet { version += 1 } }
    @Published var draft: Annotation?
    @Published var cropRect: CGRect?
    @Published var tool: EditorTool {
        didSet {
            if tool != .crop { cropRect = nil }
            if tool != .select { selection = nil }
        }
    }
    @Published var color: Color = Color(red: 1.0, green: 0.27, blue: 0.23)
    @Published var widthLevel: Int = 1
    @Published var textSizeLevel: Int = 1
    @Published var pendingTextPoint: CGPoint?
    @Published var pendingText = ""
    @Published var selection: UUID?
    @Published var status: String?
    /// Points per image point: nil fits the window, 1 is actual size.
    @Published var zoom: CGFloat?

    // Ask Claude about the image
    @Published var askVisible = false
    @Published var question = ""
    @Published var answer = ""
    @Published private(set) var asking = false
    @Published var askError: String?

    /// Pixels per point of the source image: 2 for Retina screenshots.
    let pixelScale: CGFloat
    /// The editor window, for sheets.
    weak var window: NSWindow?
    /// The zoom that fits the window, reported by the view.
    var fitZoom: CGFloat = 1

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private static let undoLimit = 50
    private var askTask: Task<Void, Never>?
    private var move: (id: UUID, original: Annotation, start: CGPoint, moved: Bool)?
    /// Bumped on every change, so the flattened export can be reused until something changes.
    private var version = 0
    private var exportCache: (version: Int, image: CGImage)?
    private var obscureCache: [UUID: (rect: CGRect, source: ObjectIdentifier, image: CGImage)] = [:]
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

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

    /// Text heights in points.
    static let textSizes: [CGFloat] = [16, 28, 48]
    /// Stroke widths in points.
    static let strokeWidths: [CGFloat] = [3, 6, 10]
    /// Long edge sent to Claude: current models read images up to this size without shrinking them.
    nonisolated static let uploadLongEdge: CGFloat = 2576

    init?(image: NSImage, tool: EditorTool = .arrow) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        base = cg
        pixelScale = image.size.width > 0 ? max(1, CGFloat(cg.width) / image.size.width) : 1
        self.tool = tool
    }

    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Stroke width in image pixels.
    var strokeWidth: CGFloat { Self.strokeWidths[widthLevel] * pixelScale }
    /// Text height in image pixels.
    var fontSize: CGFloat { Self.textSizes[textSizeLevel] * pixelScale }

    // MARK: - History

    private func pushUndo() {
        undoStack.append(Snapshot(base: base, annotations: annotations))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        commitText()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, annotations: annotations))
        base = last.base
        annotations = last.annotations
        selection = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, annotations: annotations))
        base = next.base
        annotations = next.annotations
        selection = nil
    }

    // MARK: - Gestures (coordinates are already in image pixels)

    func dragChanged(start: CGPoint, current: CGPoint) {
        let a = clamp(start), b = clamp(current)
        switch tool {
        case .select:
            dragSelection(start: a, current: b)
        case .pen, .marker:
            if case .pen(var pts)? = draft?.kind {
                pts.append(b); draft?.kind = .pen(pts)
            } else if case .marker(var pts)? = draft?.kind {
                pts.append(b); draft?.kind = .marker(pts)
            } else {
                draft = Annotation(kind: tool == .pen ? .pen([a, b]) : .marker([a, b]), color: color, width: strokeWidth)
            }
        case .rect: draft = Annotation(kind: .rect(a, b), color: color, width: strokeWidth)
        case .blur: draft = Annotation(kind: .pixelate(a, b), color: color, width: strokeWidth)
        case .redact: draft = Annotation(kind: .redact(a, b), color: .black, width: strokeWidth)
        case .ellipse: draft = Annotation(kind: .ellipse(a, b), color: color, width: strokeWidth)
        case .line: draft = Annotation(kind: .line(a, b), color: color, width: strokeWidth)
        case .arrow: draft = Annotation(kind: .arrow(a, b), color: color, width: strokeWidth)
        case .crop:
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            // A click or a tiny drag doesn't start a crop (it used to dim the whole image)
            cropRect = rect.width >= Self.minCrop && rect.height >= Self.minCrop ? rect : nil
        case .text:
            break
        }
    }

    /// Smallest crop side in pixels.
    static let minCrop: CGFloat = 8

    func dragEnded(start: CGPoint, end: CGPoint) {
        switch tool {
        case .text:
            commitText()
            pendingTextPoint = clamp(end)
            pendingText = ""
            return
        case .select:
            if let move, move.moved { Log.info("editor: moved annotation") }
            move = nil
            return
        case .crop:
            if let r = cropRect, r.width < Self.minCrop || r.height < Self.minCrop { cropRect = nil }
            return
        default:
            break
        }
        guard let d = draft else { return }
        draft = nil
        let moved = hypot(end.x - start.x, end.y - start.y)
        let isStroke: Bool = { if case .pen = d.kind { return true }; if case .marker = d.kind { return true }; return false }()
        guard moved > 3 || isStroke else { return }
        pushUndo()
        annotations.append(d)
    }

    private func dragSelection(start: CGPoint, current: CGPoint) {
        if move == nil {
            let tolerance = 6 * pixelScale
            guard let hit = annotations.last(where: { $0.hitTest(start, tolerance: tolerance) }) else {
                selection = nil
                return
            }
            selection = hit.id
            move = (hit.id, hit, start, false)
        }
        guard var m = move, let index = annotations.firstIndex(where: { $0.id == m.id }) else { return }
        let delta = CGSize(width: current.x - m.start.x, height: current.y - m.start.y)
        guard m.moved || hypot(delta.width, delta.height) > 2 else { return }
        if !m.moved {
            pushUndo()
            m.moved = true
            move = m
        }
        annotations[index] = m.original.offset(by: delta)
    }

    func deleteSelection() {
        guard let id = selection, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations.remove(at: index)
        selection = nil
    }

    var selectedBounds: CGRect? {
        guard let id = selection else { return nil }
        return annotations.first { $0.id == id }?.bounds
    }

    func commitText() {
        defer { pendingTextPoint = nil; pendingText = "" }
        guard let at = pendingTextPoint, !pendingText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        pushUndo()
        annotations.append(Annotation(kind: .text(at, pendingText), color: color, width: strokeWidth, fontSize: fontSize))
    }

    func cancelText() {
        pendingTextPoint = nil
        pendingText = ""
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), CGFloat(base.width)), y: min(max(p.y, 0), CGFloat(base.height)))
    }

    // MARK: - Crop

    func applyCrop() {
        guard let rect = cropRect?.integral, rect.width >= Self.minCrop, rect.height >= Self.minCrop,
              let flat = renderCGImage(),
              let cropped = flat.cropping(to: rect) else { return }
        pushUndo()
        base = cropped
        annotations = []
        cropRect = nil
        tool = .arrow
    }

    func cancelCrop() { cropRect = nil }

    // MARK: - Keyboard

    /// Runs a keyboard command. Returns false when there was nothing to do, so the key goes on.
    @discardableResult
    func perform(_ command: EditorCommand) -> Bool {
        switch command {
        case .tool(let t):
            commitText()
            tool = t
        case .undo: undo()
        case .redo: redo()
        case .copy: copyToClipboard()
        case .save: save()
        case .zoomIn: setZoom((zoom ?? fitZoom) * 1.25)
        case .zoomOut: setZoom((zoom ?? fitZoom) / 1.25)
        case .zoomFit: zoom = nil
        case .zoomActual: zoom = 1
        case .confirm:
            guard cropRect != nil else { return false }
            applyCrop()
        case .cancel:
            if cropRect != nil { cancelCrop() } else if selection != nil { selection = nil } else { return false }
        case .delete:
            guard selection != nil else { return false }
            deleteSelection()
        }
        return true
    }

    /// Between 10 % and 800 %; zooming back to the fitting size snaps to "fit".
    func setZoom(_ value: CGFloat) {
        let z = min(max(value, 0.1), 8)
        zoom = abs(z - fitZoom) < 0.01 ? nil : z
    }

    // MARK: - Drawing and export

    /// The flattened image at full size, in the source's color space. Reused until something changes.
    func renderCGImage() -> CGImage? {
        if let cache = exportCache, cache.version == version { return cache.image }
        let size = imageSize
        let view = Canvas { [self] ctx, _ in
            drawContent(in: &ctx, scale: 1, includeDraft: false, outlines: false)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let space = Self.exportColorSpace(for: base.colorSpace)
        var result: CGImage?
        renderer.render { rendered, draw in
            guard let ctx = CGContext(data: nil, width: Int(rendered.width), height: Int(rendered.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            draw(ctx)
            result = ctx.makeImage()
        }
        if let result { exportCache = (version, result) }
        return result
    }

    /// The color space for 8-bit rendering: the source's own when it is RGB and an 8-bit context
    /// supports it, otherwise sRGB. Extended spaces (extendedSRGB, extendedDisplayP3…) can't back
    /// an 8-bit context, and without this fallback Copy, Save, Pin, Ask, Crop and Done did nothing.
    nonisolated static func exportColorSpace(for source: CGColorSpace?) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let source, source.model == .rgb else { return srgb }
        let probe = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: source,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return probe == nil ? srgb : source
    }

    /// Draws the base image and all annotations. `scale` maps image pixels to canvas points.
    func drawContent(in ctx: inout GraphicsContext, scale: CGFloat, includeDraft: Bool, outlines: Bool) {
        let frame = CGRect(x: 0, y: 0, width: CGFloat(base.width) * scale, height: CGFloat(base.height) * scale)
        ctx.draw(Image(decorative: base, scale: 1), in: frame)
        for a in annotations {
            if let r = a.pixelateRect {
                if let image = obscured(a.id, rect: r) {
                    let rect = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                    ctx.draw(Image(decorative: image, scale: 1), in: rect)
                }
                if outlines { a.draw(in: &ctx, scale: scale) }
            } else {
                a.draw(in: &ctx, scale: scale)
            }
        }
        // A blur being dragged shows only its outline; the pixels are made once, on release
        if includeDraft, let draft { draft.draw(in: &ctx, scale: scale) }
    }

    /// Pixel block size for hiding a region: large enough that a line of text inside turns into
    /// two or three blocks, which de-pixelation tools can't read back.
    nonisolated static func blockSize(for rect: CGRect, pixelScale: CGFloat) -> CGFloat {
        max(10 * pixelScale, min(rect.width, rect.height) / 6)
    }

    /// The region pixelated and then blurred, cached per annotation.
    private func obscured(_ id: UUID, rect: CGRect) -> CGImage? {
        let source = ObjectIdentifier(base)
        let r = rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard !r.isEmpty else { return nil }
        if let cached = obscureCache[id], cached.rect == r, cached.source == source { return cached.image }
        guard let crop = base.cropping(to: r) else { return nil }
        let block = Self.blockSize(for: r, pixelScale: pixelScale)
        let input = CIImage(cgImage: crop)
        let pixelated = input.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: 0, y: 0),
        ])
        let blurred = pixelated.applyingGaussianBlur(sigma: block * 0.45).cropped(to: input.extent)
        guard let out = Self.ciContext.createCGImage(blurred, from: input.extent, format: .RGBA8,
                                                     colorSpace: Self.exportColorSpace(for: base.colorSpace)) else { return nil }
        obscureCache[id] = (r, source, out)
        return out
    }

    func renderNSImage() -> NSImage? {
        guard let cg = renderCGImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / pixelScale,
                                                  height: CGFloat(cg.height) / pixelScale))
    }

    /// PNG on the clipboard, encoded off the main thread. `then` runs once it is there, or once
    /// copying failed, and says which.
    func copyToClipboard(then: (@MainActor (_ copied: Bool) -> Void)? = nil) {
        commitText()
        guard let cg = renderCGImage() else {
            Log.info("editor render failed")
            flash(String(localized: "Not copied"))
            then?(false)
            return
        }
        let scale = pixelScale
        Task { @MainActor in
            let png = await Task.detached(priority: .userInitiated) { try? ImageExport.encode(cg, as: .png, pixelScale: scale) }.value
            if let png {
                ImageExport.copyPNG(png)
                flash(String(localized: "Copied"))
            } else {
                flash(String(localized: "Not copied"))
            }
            then?(png != nil)
        }
    }

    /// Copies the text in the image, read on device.
    func copyRecognizedText() {
        commitText()
        guard let cg = renderCGImage() else { return }
        Task { @MainActor in
            let found = await TextRecognizer.copyText(from: cg)
            flash(found ? String(localized: "Text copied") : String(localized: "No text found"))
        }
    }

    /// A Save sheet on the editor window, in the folder and format from Settings → Screenshots & Text.
    func save() {
        commitText()
        guard let window, let cg = renderCGImage() else { return }
        let settings = CaptureSettings.shared
        let format = settings.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ImageExport.baseName() + "." + format.fileExtension
        panel.directoryURL = settings.saveFolderURL
        let scale = pixelScale
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                _ = Task { @MainActor in
                    let result = await Task.detached(priority: .userInitiated) { () -> Error? in
                        do {
                            try ImageExport.encode(cg, as: format, pixelScale: scale).write(to: url, options: .atomic)
                            return nil
                        } catch {
                            return error
                        }
                    }.value
                    if let failure = result {
                        self?.showSaveError(failure)
                    } else {
                        self?.flash(String(localized: "Saved"))
                    }
                }
            }
        }
    }

    private func showSaveError(_ error: Error) {
        Log.info("editor save failed: \(error)")
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "The image couldn’t be saved")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: - Ask Claude

    func askClaude() {
        guard !asking else { return }
        commitText()
        guard let cg = renderCGImage() else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = q.isEmpty ? String(localized: "What is on this screenshot? Point out anything important.") : q
        asking = true
        askError = nil
        answer = ""
        askTask = Task { @MainActor [weak self] in
            let png = await Task.detached(priority: .userInitiated) { Self.pngForUpload(cg) }.value
            do {
                guard let png else { throw ImageExport.Failure.encode }
                let reply = try await ClaudeEngine.ask(about: png, question: prompt)
                guard !Task.isCancelled else { return }
                self?.answer = reply
            } catch {
                guard !Task.isCancelled else { return }
                self?.askError = error.localizedDescription
            }
            self?.asking = false
        }
    }

    /// The window is closing: stop work that would land in a window nobody sees.
    func close() {
        askTask?.cancel()
        askTask = nil
        asking = false
    }

    /// Downscales to `uploadLongEdge` on the long edge and encodes PNG.
    nonisolated static func pngForUpload(_ image: CGImage) -> Data? {
        let longEdge = CGFloat(max(image.width, image.height))
        let k = min(1, uploadLongEdge / longEdge)
        if k == 1 { return try? ImageExport.encode(image, as: .png, pixelScale: 1) }
        let w = Int((CGFloat(image.width) * k).rounded()), h = Int((CGFloat(image.height) * k).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return try? ImageExport.encode(scaled, as: .png, pixelScale: 1)
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.status == text { self?.status = nil }
        }
    }
}
