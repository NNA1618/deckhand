import AppKit

/// Brings a session's window forward: the exact Terminal or iTerm tab, the editor window
/// with the project folder, or else the app itself.
@MainActor
enum ClaudeReveal {
    /// Editors that focus the window already showing a folder when asked to open it.
    static let folderEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
    ]

    static func reveal(_ session: ClaudeSession) {
        guard let bundleId = session.app,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let tty = session.process.flatMap { ProcessRunner.details(pid: $0.pid)?.tty }
        if let tty, let script = tabScript(bundleId: bundleId, tty: tty) {
            Task {
                if case .failure = await AppleScriptRunner.shared.run(script, timeout: 3) { open(appURL) }
            }
        } else if folderEditors.contains(bundleId), !session.cwd.isEmpty {
            let folder = URL(fileURLWithPath: session.cwd, isDirectory: true)
            NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration()) { _, _ in }
        } else {
            open(appURL)
        }
    }

    /// Opening through Launch Services brings the app forward even though the notch panel
    /// never makes Deckhand the active app, which `NSRunningApplication.activate` needs.
    private static func open(_ appURL: URL) {
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration()) { _, _ in }
    }

    private static func configuration() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return config
    }

    /// AppleScript that selects the tab on `tty` and brings its window forward.
    /// macOS asks once for permission to control the terminal (Automation).
    static func tabScript(bundleId: String, tty: String) -> String? {
        let quoted = "\"" + tty.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") + "\""
        switch bundleId {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(quoted) then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            error "not found" number -1728
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \(quoted) then
                                select t
                                select w
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            error "not found" number -1728
            """
        default:
            return nil
        }
    }
}
