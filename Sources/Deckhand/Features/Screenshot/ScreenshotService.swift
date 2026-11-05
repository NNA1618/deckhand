import AppKit
import Vision
import ImageIO

/// Runs the system `screencapture` tool. It writes to a temporary PNG, never to the desktop,
/// and shows no floating thumbnail. Deckhand puts the result on the clipboard itself.
@MainActor
enum ScreenshotService {
    enum Mode {
        /// Drag an area; Space switches to picking a window.
        case area
        /// Click a window.
        case window
        /// The whole display under the pointer, at once.
        case screen
        /// Drag an area for text recognition: always silent.
        case text
    }

    private(set) static var isRunning = false

    /// Calls back with the PNG file, or nil when the user cancelled (Esc, or nothing selected)
    /// or the tool failed. The caller deletes the file.
    static func capture(_ mode: Mode, sound: Bool, completion: @escaping @MainActor (URL?) -> Void) {
        guard !isRunning else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("deckhand-capture-\(UUID().uuidString).png")
        let args = arguments(for: mode, sound: sound, screen: displayNumberUnderPointer()) + [file.path]
        isRunning = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isRunning = false
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    Log.info("screencapture \(args.dropLast().joined(separator: " ")) status=\(status) bytes=\(size)")
                    completion(size > 0 ? file : nil)
                }
            }
        }
        do {
            try process.run()
        } catch {
            isRunning = false
            Log.info("screencapture failed to start: \(error)")
            completion(nil)
        }
    }

    /// `screencapture` flags: -i interactive, -w window only, -s area only, -D display, -x silent, -t format.
    static func arguments(for mode: Mode, sound: Bool, screen: Int?) -> [String] {
        var args: [String]
        switch mode {
        case .area: args = ["-i"]
        case .window: args = ["-i", "-w"]
        case .text: args = ["-i", "-s"]
        case .screen: args = screen.map { ["-D", String($0)] } ?? ["-m"]
        }
        if !sound || mode == .text { args.append("-x") }
        return args + ["-t", "png"]
    }

    /// `screencapture -D` counts displays from 1 in the order of the active display list.
    private static func displayNumberUnderPointer() -> Int? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.firstIndex(of: id).map { $0 + 1 }
    }
}

/// Screen Recording permission. `screencapture` runs on Deckhand's permission: without it macOS
/// quietly returns the desktop without other apps' windows, so Deckhand checks first.
@MainActor
enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private static var alertShown = false

    /// Explains what is missing and offers to fix it. Nothing opens unless the user clicks.
    static func explainMissing() {
        guard !alertShown else { return }
        alertShown = true
        // Let the shortcut's key-up and the panel's close finish first
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Allow Screen Recording for Deckhand")
            alert.informativeText = String(localized: "Without it, macOS gives Deckhand only the desktop, without other apps’ windows. Turn on Deckhand in Privacy & Security → Screen & System Audio Recording, then quit and reopen Deckhand.\n\nIf Deckhand is already on, turn it off and on again: macOS can reset it after an update.")
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Not Now"))
            NSApp.activate()
            let answer = alert.runModal()
            alertShown = false
            guard answer == .alertFirstButtonReturn else { return }
            let settings = CaptureSettings.shared
            if !settings.askedForScreenRecording {
                // The first request adds Deckhand to the list and shows macOS's own prompt with its own button
                settings.askedForScreenRecording = true
                if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(settingsURL) }
            } else {
                NSWorkspace.shared.open(settingsURL)
            }
        }
    }
}

/// How text is recognized. Built from `CaptureSettings` on the main actor, used off it.
struct OCROptions: Equatable, Sendable {
    var languages: [String]
    var autoDetect: Bool
    var languageCorrection: Bool
    var keepLineBreaks: Bool

    static let standard = OCROptions(languages: ["en-US"], autoDetect: false, languageCorrection: true, keepLineBreaks: true)

    /// Vision's accurate recognizer on macOS 15. The real list comes from `supportedLanguages()`;
    /// this one is only for picking defaults without loading Vision at launch.
    static let knownLanguages = [
        "en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant",
        "ko-KR", "ja-JP", "ru-RU", "uk-UA", "th-TH", "vi-VT", "ar-SA", "ars-SA", "tr-TR", "id-ID",
        "cs-CZ", "da-DK", "nl-NL", "no-NO", "nn-NO", "nb-NO", "ms-MY", "pl-PL", "ro-RO", "sv-SE",
    ]

    /// The user's languages that Vision can read, in their order, plus English.
    static func defaultLanguages(preferred: [String], supported: [String] = knownLanguages) -> [String] {
        var result: [String] = []
        for code in preferred {
            if let match = bestMatch(for: code, in: supported), !result.contains(match) { result.append(match) }
        }
        if !result.contains("en-US") && supported.contains("en-US") { result.append("en-US") }
        return result
    }

    /// "ru" or "ru-RU" → "ru-RU"; "zh-Hant-TW" → "zh-Hant".
    static func bestMatch(for code: String, in supported: [String]) -> String? {
        if supported.contains(code) { return code }
        let parts = code.split(separator: "-").map(String.init)
        guard let lang = parts.first else { return nil }
        if parts.count > 1, let scripted = supported.first(where: { $0 == "\(lang)-\(parts[1])" }) { return scripted }
        return supported.first { $0.split(separator: "-").first.map(String.init) == lang }
    }

    /// Languages to hand to Vision: the chosen ones it supports, never an empty list.
    func recognitionLanguages(supported: [String]) -> [String] {
        let usable = languages.filter { supported.contains($0) }
        return usable.isEmpty ? ["en-US"] : usable
    }

    /// Lines as Vision returns them. Without line breaks they become one paragraph,
    /// and words split by a hyphen at the end of a line are joined again.
    static func join(_ lines: [String], keepLineBreaks: Bool) -> String {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if keepLineBreaks { return trimmed.joined(separator: "\n") }
        var out = ""
        for line in trimmed {
            if out.hasSuffix("-"), let first = line.first, first.isLowercase {
                out.removeLast()
                out += line
            } else {
                out += out.isEmpty ? line : " " + line
            }
        }
        return out
    }
}

/// What text capture found.
enum TextCaptureResult: Equatable {
    case text(String)
    case qrCode(String)
    case barcode(String)
    case nothing

    struct Code {
        var payload: String
        var isQR: Bool
        /// Share of the captured area the code covers, 0…1.
        var area: Double
    }

    /// A code wins when there is no text, or when it is a big part of the capture
    /// (the text Vision reads around a QR code is usually a caption).
    static func decide(text: String?, codes: [Code]) -> TextCaptureResult {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !(text ?? "").isEmpty
        if let code = codes.filter({ !$0.payload.isEmpty }).max(by: { $0.area < $1.area }),
           !hasText || code.area >= 0.15 {
            return code.isQR ? .qrCode(code.payload) : .barcode(code.payload)
        }
        return hasText ? .text(text!) : .nothing
    }

    /// The string to copy.
    var payload: String? {
        switch self {
        case .text(let s), .qrCode(let s), .barcode(let s): return s
        case .nothing: return nil
        }
    }
}

/// On-device text and barcode recognition with the Vision framework.
enum TextRecognizer {
    /// Vision's own list for the accurate recognizer. Loads the model, so call it off the main thread.
    static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? OCROptions.knownLanguages
    }

    static func read(at url: URL, options: OCROptions) -> TextCaptureResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .nothing }
        return read(image, options: options)
    }

    static func read(_ image: CGImage, options: OCROptions) -> TextCaptureResult {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = options.languageCorrection
        text.automaticallyDetectsLanguage = options.autoDetect
        text.recognitionLanguages = options.recognitionLanguages(supported: supportedLanguages())
        let codes = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, codes])

        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let found = (codes.results ?? []).map { obs in
            TextCaptureResult.Code(payload: obs.payloadStringValue ?? "", isQR: obs.symbology == .qr,
                                   area: Double(obs.boundingBox.width * obs.boundingBox.height))
        }
        return TextCaptureResult.decide(text: OCROptions.join(lines, keepLineBreaks: options.keepLineBreaks), codes: found)
    }

    /// Recognizes off the main thread and copies the text (or a code's content). Returns whether anything was found.
    @MainActor
    static func copyText(fromFile url: URL) async -> Bool {
        let options = CaptureSettings.shared.ocrOptions
        let result = await Task.detached(priority: .userInitiated) { read(at: url, options: options) }.value
        return put(result)
    }

    @MainActor
    static func copyText(from image: CGImage) async -> Bool {
        let options = CaptureSettings.shared.ocrOptions
        let result = await Task.detached(priority: .userInitiated) { read(image, options: options) }.value
        return put(result)
    }

    @MainActor
    private static func put(_ result: TextCaptureResult) -> Bool {
        guard let text = result.payload else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }
}
