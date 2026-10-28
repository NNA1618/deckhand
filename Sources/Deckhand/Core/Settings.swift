import Foundation
import Combine

/// User settings in UserDefaults. The Claude API key is in the Keychain instead.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Passwords paste normally but stay out of the clipboard history by default.
    @Published var savePasswordsToHistory: Bool { didSet { d.set(savePasswordsToHistory, forKey: "savePasswordsToHistory") } }
    /// 0 means unlimited.
    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: "excludedApps") } }
    @Published var claudeInstructions: String { didSet { d.set(claudeInstructions, forKey: "claudeInstructions") } }
    @Published var watchedFolders: [String] { didSet { d.set(watchedFolders, forKey: "watchedFolders") } }
    @Published var screenshotToast: Bool { didSet { d.set(screenshotToast, forKey: "screenshotToast") } }

    private init() {
        d.register(defaults: [
            "savePasswordsToHistory": false,
            "historyLimit": 500,
            "screenshotToast": true,
        ])
        savePasswordsToHistory = d.bool(forKey: "savePasswordsToHistory")
        historyLimit = d.integer(forKey: "historyLimit")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        claudeInstructions = d.string(forKey: "claudeInstructions") ?? ""
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        watchedFolders = d.stringArray(forKey: "watchedFolders") ?? [downloads]
        screenshotToast = d.bool(forKey: "screenshotToast")
    }
}
