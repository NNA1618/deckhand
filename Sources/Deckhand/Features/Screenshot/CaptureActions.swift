import AppKit

/// Area capture, text capture and the color picker, started from shortcuts and the menu bar.
/// Owned by the capture and hotkeys workstream.
@MainActor
enum CaptureActions {
    static func captureArea(notch: NotchController) {
        notch.close()
        ScreenshotService.captureRegion { [weak notch] in
            guard Settings.shared.screenshotToast else { return }
            notch?.showToast(symbol: "camera.viewfinder", text: String(localized: "Copied to clipboard"))
        }
    }

    static func captureText(notch: NotchController) {
        notch.close()
        ScreenshotService.captureText { [weak notch] text in
            guard let text else {
                notch?.showToast(symbol: "text.viewfinder", text: String(localized: "No text found"))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notch?.showToast(symbol: "text.viewfinder", text: String(localized: "Text copied"))
        }
    }

    static func pickColor(notch: NotchController) {
        notch.close()
        NSColorSampler().show { [weak notch] color in
            guard let color, let rgb = color.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X",
                             Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()),
                             Int((rgb.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            MainActor.assumeIsolated { notch?.showToast(symbol: "eyedropper", text: hex) }
        }
    }
}
