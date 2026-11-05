import Foundation

/// Settings of Settings → Codex, in UserDefaults under `codex*` keys.
/// Notice defaults match Claude Code's, so connecting Codex behaves the way people already know.
@MainActor
final class CodexSettings: ObservableObject {
    static let shared = CodexSettings()
    private let d: UserDefaults

    /// Answer Codex's permission prompts from the notch. Off by default: while it is on,
    /// Codex shows its own prompt only after `approvalWait` seconds without an answer.
    @Published var approveFromNotch: Bool { didSet { d.set(approveFromNotch, forKey: "codexApproveFromNotch") } }
    /// Seconds Codex waits for an answer from the notch.
    @Published var approvalWait: Int { didSet { d.set(approvalWait, forKey: "codexApprovalWait") } }
    /// A notice when a Codex session needs you.
    @Published var noticeNeedsYou: Bool { didSet { d.set(noticeNeedsYou, forKey: "noticeCodexNeedsYou") } }
    /// A notice when a Codex session finishes a task.
    @Published var doneNotice: Bool { didSet { d.set(doneNotice, forKey: "codexDoneNotice") } }
    /// The sound for "needs you"; empty means none.
    @Published var soundNeedsYou: String { didSet { d.set(soundNeedsYou, forKey: "soundCodexNeedsYou") } }
    /// Set once the first Codex event arrives after Connect: until then the user still has to approve
    /// Deckhand's hooks in Codex.
    @Published var hooksSeen: Bool { didSet { d.set(hooksSeen, forKey: "codexHooksSeen") } }

    static let approvalWaits = [15, 30, 60]
    static let defaultSound = "Ping"

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: [
            "codexApproveFromNotch": false,
            "codexApprovalWait": 30,
            "noticeCodexNeedsYou": true,
            "codexDoneNotice": true,
            "soundCodexNeedsYou": Self.defaultSound,
            "codexHooksSeen": false,
        ])
        approveFromNotch = d.bool(forKey: "codexApproveFromNotch")
        approvalWait = d.integer(forKey: "codexApprovalWait")
        noticeNeedsYou = d.bool(forKey: "noticeCodexNeedsYou")
        doneNotice = d.bool(forKey: "codexDoneNotice")
        soundNeedsYou = d.string(forKey: "soundCodexNeedsYou") ?? Self.defaultSound
        hooksSeen = d.bool(forKey: "codexHooksSeen")
    }

    /// Restores this section's defaults; the connection itself stays.
    func restoreDefaults() {
        approveFromNotch = false
        approvalWait = 30
        noticeNeedsYou = true
        doneNotice = true
        soundNeedsYou = Self.defaultSound
    }
}
