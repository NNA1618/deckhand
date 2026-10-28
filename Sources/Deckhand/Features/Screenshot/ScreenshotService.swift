import AppKit
import Vision

/// Captures a screen area straight to the clipboard: no file on the desktop, no floating thumbnail.
/// The selection UI is the system screencapture in mouse-selection mode.
@MainActor
enum ScreenshotService {
    private static var running = false

    static func captureRegion(onCopied: @escaping @MainActor () -> Void) {
        let before = NSPasteboard.general.changeCount
        // -i interactive, -s mouse selection only, -c to clipboard, -x no sound
        run(["-i", "-s", "-c", "-x"]) { _ in
            if NSPasteboard.general.changeCount != before { onCopied() }
        }
    }

    /// Lets the user select an area, recognizes its text on device and returns it.
    static func captureText(completion: @escaping @MainActor (String?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-ocr-\(UUID().uuidString).png")
        run(["-i", "-s", "-x", file.path]) { _ in
            guard FileManager.default.fileExists(atPath: file.path) else { return completion(nil) }
            Task.detached(priority: .userInitiated) {
                let text = TextRecognizer.recognize(at: file)
                try? FileManager.default.removeItem(at: file)
                await MainActor.run { completion(text) }
            }
        }
    }

    private static func run(_ args: [String], then: @escaping @MainActor (Int32) -> Void) {
        guard !running else { return }
        running = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    running = false
                    Log.info("screencapture \(args.first ?? "") status=\(status)")
                    then(status)
                }
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            Log.info("screencapture failed: \(error)")
        }
    }
}

/// On-device text recognition with the Vision framework.
enum TextRecognizer {
    static func recognize(at url: URL) -> String? {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
