import AppKit

/// `Deckhand --selftest` runs logic checks without UI and exits.
/// Exists because the test frameworks are not available without Xcode.
/// Each area keeps its checks in its own `SelfTest+Area.swift` file.
@MainActor
enum SelfTest {
    typealias Check = (Bool, String) -> Void

    static func run() -> Bool {
        var ok = true
        let check: Check = { cond, name in
            Log.info("selftest \(cond ? "ok  " : "FAIL") \(name)")
            print("\(cond ? "ok  " : "FAIL") \(name)")
            if !cond { ok = false }
        }
        capture(check)
        clipboard(check)
        prompts(check)
        translate(check)
        media(check)
        claude(check)
        codex(check)
        notch(check)
        panel(check)
        utilities(check)
        settings(check)
        localization(check)
        updates(check)
        return ok
    }
}
