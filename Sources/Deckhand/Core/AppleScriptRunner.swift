import AppKit
import CoreServices

/// Runs AppleScript off the main thread with a timeout, so a slow or stuck app
/// (System Events, Music, a browser) can never freeze Deckhand.
/// All scripts run on one serial queue because NSAppleScript is not thread-safe.
/// Shared by several areas; change it only in a backward-compatible way.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    struct Failure: Error, Sendable {
        /// The AppleScript error number, e.g. -1743 (not allowed), -1712 (timed out), -600 (app not running).
        let code: Int
        let message: String
        var notAllowed: Bool { code == -1743 }
        var timedOut: Bool { code == -1712 }
    }

    private let queue = DispatchQueue(label: "deckhand.applescript", qos: .userInitiated)
    private var compiled: [String: NSAppleScript] = [:]

    private init() {}

    /// Runs `source` wrapped in `with timeout of <timeout> seconds`. Returns the result's string value.
    func run(_ source: String, timeout: Int = 3) async -> Result<String?, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.runNow(source, timeout: timeout))
            }
        }
    }

    /// Runs and returns the raw descriptor, for scripts that return booleans or lists.
    func runDescriptor(_ source: String, timeout: Int = 3) async -> Result<NSAppleEventDescriptor, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.execute(source, timeout: timeout))
            }
        }
    }

    private func runNow(_ source: String, timeout: Int) -> Result<String?, Failure> {
        execute(source, timeout: timeout).map { $0.stringValue }
    }

    private func execute(_ source: String, timeout: Int) -> Result<NSAppleEventDescriptor, Failure> {
        let wrapped = "with timeout of \(timeout) seconds\n\(source)\nend timeout"
        let script: NSAppleScript
        if let cached = compiled[wrapped] {
            script = cached
        } else if let made = NSAppleScript(source: wrapped) {
            compiled[wrapped] = made
            script = made
        } else {
            return .failure(Failure(code: -2700, message: "Could not compile the script"))
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            return .failure(Failure(code: code, message: message))
        }
        return .success(result)
    }
}

/// Whether Deckhand may send Apple Events to an app (Settings → Privacy & Security → Automation).
enum AutomationPermission: Equatable, Sendable {
    case allowed, denied, notAsked, appNotRunning, unknown

    /// Checks without showing the macOS prompt unless `ask` is true. With `ask`, call it only
    /// after a user action, and off the main thread: it can wait for the user to answer.
    static func status(bundleId: String, ask: Bool = false) -> AutomationPermission {
        var target = AEAddressDesc()
        let id = Array(bundleId.utf8)
        let created = id.withUnsafeBufferPointer {
            AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case -1744: return .notAsked          // errAEEventWouldRequireUserConsent
        case OSStatus(procNotFound): return .appNotRunning
        default: return .unknown
        }
    }
}
