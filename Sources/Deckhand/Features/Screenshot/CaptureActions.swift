import AppKit

/// Screenshots, text capture and the color picker, started from shortcuts, the menu bar and Home.
/// Owned by the capture and hotkeys workstream.
@MainActor
enum CaptureActions {
    enum Mode {
        case area, window, screen
        /// The screen under the pointer after 3 seconds, to catch open menus and hover states.
        case delayedScreen
        /// An area, then the editor, whatever "After capture" says.
        case areaAndEdit
    }

    static let delay: TimeInterval = 3
    /// How long the panel takes to animate out (0.45 s) plus a margin, so a screen or window
    /// capture started while it was open doesn't catch it half closed.
    static let panelCloseDelay: TimeInterval = 0.5
    private static var delayedPending = false
    /// Kept alive while the system color sampler is up.
    private static var sampler: NSColorSampler?

    static func captureArea(notch: NotchController) { capture(.area, notch: notch) }

    static func capture(_ mode: Mode, notch: NotchController) {
        guard !ScreenshotService.isRunning, !delayedPending else { return }
        let panelWasOpen = notch.viewModel.isOpen
        notch.close()
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.explainMissing()
            return
        }
        let settings = CaptureSettings.shared
        let after: CaptureAfterAction = mode == .areaAndEdit ? .copyAndEdit : settings.afterCapture
        let serviceMode: ScreenshotService.Mode
        switch mode {
        case .area, .areaAndEdit: serviceMode = .area
        case .window: serviceMode = .window
        case .screen, .delayedScreen: serviceMode = .screen
        }

        notch.suspendHover(true)
        let run: @MainActor @Sendable () -> Void = { [weak notch] in
            delayedPending = false
            ScreenshotService.capture(serviceMode, sound: settings.shutterSound) { file in
                notch?.suspendHover(false)
                // No file: Esc, a click without a selection, or the tool failed. Stay quiet.
                guard let file, let notch else { return }
                finish(file: file, after: after, notch: notch)
            }
        }
        if mode == .delayedScreen {
            delayedPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run)
        } else if panelWasOpen, mode == .screen || mode == .window {
            // An area selection is drawn over the live screen, so only these two wait
            delayedPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + panelCloseDelay, execute: run)
        } else {
            run()
        }
    }

    /// Copies the capture, then edits or saves it.
    private static func finish(file: URL, after: CaptureAfterAction, notch: NotchController) {
        let format = CaptureSettings.shared.format
        let folder = CaptureSettings.shared.saveFolderURL
        Task { @MainActor in
            let read = await Task.detached(priority: .userInitiated) { () -> Data? in
                defer { try? FileManager.default.removeItem(at: file) }
                return try? Data(contentsOf: file)
            }.value
            guard let png = read else {
                notch.showToast(symbol: "exclamationmark.triangle", text: String(localized: "The screenshot couldn’t be read"))
                return
            }
            ImageExport.copyPNG(png)
            switch after {
            case .copy:
                if Settings.shared.screenshotToast {
                    notch.showToast(symbol: "camera.viewfinder", text: String(localized: "Copied to clipboard"))
                }
            case .copyAndEdit:
                if let image = NSImage(data: png) { EditorWindow.open(image: image) }
            case .copyAndSave:
                let saved = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                    Result { try ImageExport.save(ImageExport.convert(png, to: format), in: folder, format: format) }
                }.value
                switch saved {
                case .success(let url):
                    Log.info("screenshot saved to \(url.path)")
                    if Settings.shared.screenshotToast {
                        notch.showToast(symbol: "camera.viewfinder", text: String(localized: "Copied and saved"))
                    }
                case .failure(let error):
                    Log.info("screenshot save failed: \(error)")
                    // An error is always shown, whatever the notice settings say
                    notch.showToast(symbol: "exclamationmark.triangle", text: String(localized: "Copied, but not saved"))
                }
            }
        }
    }

    static func captureText(notch: NotchController) {
        guard !ScreenshotService.isRunning, !delayedPending else { return }
        notch.close()
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.explainMissing()
            return
        }
        let options = CaptureSettings.shared.ocrOptions
        notch.suspendHover(true)
        ScreenshotService.capture(.text, sound: false) { [weak notch] file in
            notch?.suspendHover(false)
            guard let file else { return }   // cancelled: no "No text found"
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) { () -> TextCaptureResult in
                    defer { try? FileManager.default.removeItem(at: file) }
                    return TextRecognizer.read(at: file, options: options)
                }.value
                if let payload = result.payload {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                }
                guard Settings.shared.noticeTextCapture else { return }
                switch result {
                case .text: notch?.showToast(symbol: "text.viewfinder", text: String(localized: "Text copied"))
                case .qrCode: notch?.showToast(symbol: "qrcode.viewfinder", text: String(localized: "QR code copied"))
                case .barcode: notch?.showToast(symbol: "barcode.viewfinder", text: String(localized: "Barcode copied"))
                case .nothing: notch?.showToast(symbol: "text.viewfinder", text: String(localized: "No text found"))
                }
            }
        }
    }

    static func pickColor(notch: NotchController) {
        guard sampler == nil else { return }
        notch.close()
        notch.suspendHover(true)
        let picker = NSColorSampler()
        sampler = picker
        picker.show { [weak notch] color in
            MainActor.assumeIsolated {
                sampler = nil
                notch?.suspendHover(false)
                guard let rgb = color?.usingColorSpace(.sRGB) else { return }
                let format = CaptureSettings.shared.colorFormat
                let (r, g, b) = (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(format.string(red: r, green: g, blue: b), forType: .string)
                if Settings.shared.noticeColor {
                    notch?.showToast(symbol: "eyedropper", text: format.notice(red: r, green: g, blue: b))
                }
            }
        }
    }
}
