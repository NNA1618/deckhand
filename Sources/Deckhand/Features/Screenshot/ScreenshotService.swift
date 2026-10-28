import AppKit

/// Captures a screen area straight to the clipboard: no file on the desktop, no floating thumbnail.
/// The selection UI is the system screencapture in mouse-selection mode.
@MainActor
enum ScreenshotService {
    private static var running = false

    static func captureRegion(onCopied: @escaping @MainActor () -> Void) {
        guard !running else { return }
        running = true
        let before = NSPasteboard.general.changeCount

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -s mouse selection only, -c to clipboard, -x no sound
        process.arguments = ["-i", "-s", "-c", "-x"]
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    running = false
                    let copied = NSPasteboard.general.changeCount != before
                    Log.info("screenshot status=\(status) copied=\(copied)")
                    if copied { onCopied() }
                }
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            Log.info("screenshot failed: \(error)")
        }
    }
}
