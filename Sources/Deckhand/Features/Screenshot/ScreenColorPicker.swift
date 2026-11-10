import AppKit
import ScreenCaptureKit

/// Deckhand's own color picker. It freezes each display into a still image, covers the display with it
/// and reads the pixel under a click.
///
/// Why not NSColorSampler: started from an accessory app that isn't active, the system sampler can keep
/// the mouse after it closes, so the pointer moves but clicks go nowhere, even after Deckhand quits.
/// Every window here belongs to Deckhand, so quitting Deckhand always gives the mouse back, and the
/// picker gives up by itself on a timeout, when another app becomes active, and on Esc or a right click.
@MainActor
final class ScreenColorPicker {
    private static var current: ScreenColorPicker?
    static var isRunning: Bool { current != nil }

    /// Longest the picker stays up without a pick.
    static let timeout: TimeInterval = 60

    private var windows: [PickerWindow] = []
    private var completion: ((NSColor?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var timer: Timer?

    /// Shows the picker on every display. `completion` gets the picked color in sRGB, or nil if cancelled.
    static func show(completion: @escaping (NSColor?) -> Void) {
        guard current == nil else { return }
        let picker = ScreenColorPicker()
        picker.completion = completion
        current = picker
        Task { await picker.start() }
    }

    private func start() async {
        let shots = await Self.captureDisplays()
        guard completion != nil else { return }
        guard !shots.isEmpty else {
            Log.info("color picker: no display image")
            finish(nil)
            return
        }
        for shot in shots {
            let window = PickerWindow(screen: shot.screen, image: shot.image)
            window.onPick = { [weak self] color in self?.finish(color) }
            window.onCancel = { [weak self] in self?.finish(nil) }
            windows.append(window)
        }
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil); return nil }   // Esc
            return event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("color picker: timed out")
                self?.finish(nil)
            }
        }
    }

    private func finish(_ color: NSColor?) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if !windows.isEmpty { NSCursor.pop() }
        for window in windows { window.orderOut(nil) }
        windows = []
        Self.current = nil
        completion(color)
    }

    // MARK: - Display images

    private struct Shot { let screen: NSScreen; let image: CGImage }

    /// A still of every display without Deckhand's own windows, in sRGB so picked values match the web.
    private static func captureDisplays() async -> [Shot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.info("color picker: shareable content failed: \(error.localizedDescription)")
            return []
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var shots: [Shot] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                shots.append(Shot(screen: screen, image: image))
            } catch {
                Log.info("color picker: capture failed: \(error.localizedDescription)")
            }
        }
        return shots
    }

    // MARK: - Geometry, kept pure for the self-test

    /// The image pixel under a point in a window `size` points big showing an image `pixels` big.
    /// Window points go up from the bottom, image rows go down from the top.
    nonisolated static func pixel(at point: CGPoint, in size: CGSize, pixels: CGSize) -> (x: Int, y: Int) {
        let sx = pixels.width / max(size.width, 1), sy = pixels.height / max(size.height, 1)
        let x = Int((point.x * sx).rounded(.down))
        let y = Int(((size.height - point.y) * sy).rounded(.down))
        return (min(max(x, 0), Int(pixels.width) - 1), min(max(y, 0), Int(pixels.height) - 1))
    }
}

/// One display's cover: the frozen image, with a loupe that follows the pointer.
@MainActor
private final class PickerWindow: NSPanel {
    var onPick: ((NSColor?) -> Void)?
    var onCancel: (() -> Void)?
    private let loupe: LoupeView

    init(screen: NSScreen, image: CGImage) {
        loupe = LoupeView(image: image)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image, loupe: loupe)
        view.onPick = { [weak self] color in self?.onPick?(color) }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
private final class PickerView: NSView {
    var onPick: ((NSColor?) -> Void)?
    var onCancel: (() -> Void)?
    private let image: CGImage
    private let bitmap: NSBitmapImageRep
    private let loupe: LoupeView

    init(frame: NSRect, image: CGImage, loupe: LoupeView) {
        self.image = image
        self.bitmap = NSBitmapImageRep(cgImage: image)
        self.loupe = loupe
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        addSubview(loupe)
        loupe.isHidden = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    private func color(at point: CGPoint) -> NSColor? {
        let p = ScreenColorPicker.pixel(at: point, in: bounds.size, pixels: pixelSize)
        return bitmap.colorAt(x: p.x, y: p.y)?.usingColorSpace(.sRGB)
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { loupe.isHidden = true }

    private func follow(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let p = ScreenColorPicker.pixel(at: point, in: bounds.size, pixels: pixelSize)
        loupe.update(center: p, color: color(at: point))
        // Keep the loupe on screen: right and above the pointer, flipped near the edges
        let size = loupe.frame.size, gap: CGFloat = 18
        var origin = CGPoint(x: point.x + gap, y: point.y + gap)
        if origin.x + size.width > bounds.maxX { origin.x = point.x - gap - size.width }
        if origin.y + size.height > bounds.maxY { origin.y = point.y - gap - size.height }
        loupe.setFrameOrigin(origin)
        loupe.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        onPick?(color(at: convert(event.locationInWindow, from: nil)))
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }
}

/// A magnified square of pixels around the pointer, with the value as it will be copied.
@MainActor
private final class LoupeView: NSView {
    private static let cells = 11
    private static let cell: CGFloat = 11
    private let image: CGImage
    private var center = (x: 0, y: 0)
    private let label = NSTextField(labelWithString: "")

    init(image: CGImage) {
        self.image = image
        let side = CGFloat(Self.cells) * Self.cell
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side + 26))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 5, width: side, height: 16)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(center: (x: Int, y: Int), color: NSColor?) {
        self.center = center
        if let color {
            let format = CaptureSettings.shared.colorFormat
            label.stringValue = format.string(red: Double(color.redComponent), green: Double(color.greenComponent),
                                              blue: Double(color.blueComponent))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = CGFloat(Self.cells) * Self.cell
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.fill(bounds)
        let half = Self.cells / 2
        let crop = CGRect(x: center.x - half, y: center.y - half, width: Self.cells, height: Self.cells)
        let grid = CGRect(x: 0, y: 26, width: side, height: side)
        if let part = image.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // Place the cropped part where it sits inside the requested square, so edges stay aligned
            let dx = CGFloat(max(0, -crop.minX)) * Self.cell
            let dyTop = CGFloat(max(0, -crop.minY)) * Self.cell
            let w = CGFloat(part.width) * Self.cell, h = CGFloat(part.height) * Self.cell
            ctx.draw(part, in: CGRect(x: grid.minX + dx, y: grid.maxY - dyTop - h, width: w, height: h))
            ctx.restoreGState()
        }
        // The pixel that will be picked
        let mid = CGRect(x: grid.minX + CGFloat(half) * Self.cell, y: grid.minY + CGFloat(half) * Self.cell,
                         width: Self.cell, height: Self.cell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(mid.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(0.75)
        ctx.stroke(mid.insetBy(dx: 0.5, dy: 0.5))
    }
}
