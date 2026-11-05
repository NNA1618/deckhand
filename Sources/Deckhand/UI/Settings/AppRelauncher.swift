import AppKit

@MainActor
enum AppRelauncher {
    /// Starts a new copy once this one has quit, so a new language takes effect.
    static func relaunch(openSettings: Bool) {
        let path = Bundle.main.bundlePath
        let args = openSettings ? " --args --settings" : ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"\(args)", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
