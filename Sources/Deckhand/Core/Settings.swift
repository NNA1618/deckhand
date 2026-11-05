import Foundation
import CoreGraphics
import Combine

/// How the open panel is drawn.
enum PanelStyle: String, CaseIterable, Identifiable {
    /// Liquid Glass that shows more of what is behind it.
    case clear
    /// Liquid Glass with a dark tint, the default.
    case tinted
    /// An opaque dark panel, no glass.
    case solid
    var id: String { rawValue }
}

enum PanelSize: String, CaseIterable, Identifiable {
    case compact, standard, large
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .compact: return CGSize(width: 720, height: 420)
        case .standard: return CGSize(width: 800, height: 480)
        case .large: return CGSize(width: 920, height: 560)
        }
    }
}

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
    @Published var watchedFolders: [String] { didSet { d.set(watchedFolders, forKey: "watchedFolders") } }
    @Published var screenshotToast: Bool { didSet { d.set(screenshotToast, forKey: "screenshotToast") } }
    @Published var showPlayingInNotch: Bool { didSet { d.set(showPlayingInNotch, forKey: "showPlayingInNotch") } }

    // Appearance and panel behaviour
    @Published var panelStyle: PanelStyle { didSet { d.set(panelStyle.rawValue, forKey: "panelStyle") } }
    /// Darkness of the glass tint, 0...0.8.
    @Published var glassTint: Double { didSet { d.set(glassTint, forKey: "glassTint") } }
    @Published var panelSize: PanelSize { didSet { d.set(panelSize.rawValue, forKey: "panelSize") } }
    @Published var hideInFullScreen: Bool { didSet { d.set(hideInFullScreen, forKey: "hideInFullScreen") } }

    /// Panel tabs the user turned off. Home always stays.
    @Published var hiddenTabs: [String] { didSet { d.set(hiddenTabs, forKey: "hiddenTabs") } }

    @Published var batteryNotices: Bool { didSet { d.set(batteryNotices, forKey: "batteryNotices") } }

    // Badges and notices around the closed notch. Shared by several areas, shown in Settings → Closed Notch.
    @Published var badgeTimer: Bool { didSet { d.set(badgeTimer, forKey: "badgeTimer") } }
    @Published var hideBadgesInFullScreen: Bool { didSet { d.set(hideBadgesInFullScreen, forKey: "hideBadgesInFullScreen") } }
    @Published var noticeTextCapture: Bool { didSet { d.set(noticeTextCapture, forKey: "noticeTextCapture") } }
    @Published var noticeColor: Bool { didSet { d.set(noticeColor, forKey: "noticeColor") } }
    @Published var noticeKeepAwake: Bool { didSet { d.set(noticeKeepAwake, forKey: "noticeKeepAwake") } }
    @Published var noticeTimer: Bool { didSet { d.set(noticeTimer, forKey: "noticeTimer") } }
    @Published var noticeCharging: Bool { didSet { d.set(noticeCharging, forKey: "noticeCharging") } }
    @Published var noticeLowBattery: Bool { didSet { d.set(noticeLowBattery, forKey: "noticeLowBattery") } }
    @Published var noticeClaudeNeedsYou: Bool { didSet { d.set(noticeClaudeNeedsYou, forKey: "noticeClaudeNeedsYou") } }
    /// Seconds a notice stays in the notch.
    @Published var toastDuration: Double { didSet { d.set(toastDuration, forKey: "toastDuration") } }
    /// System sound names; empty means no sound.
    @Published var soundClaudeNeedsYou: String { didSet { d.set(soundClaudeNeedsYou, forKey: "soundClaudeNeedsYou") } }
    @Published var soundTimer: String { didSet { d.set(soundTimer, forKey: "soundTimer") } }
    /// The menu bar icon. Without it, opening Deckhand again from Finder shows Settings.
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    /// Translate, Claude and the Recents prompt start with copied text when it looks like ordinary text.
    @Published var prefillFromClipboard: Bool { didSet { d.set(prefillFromClipboard, forKey: "prefillFromClipboard") } }

    // Claude
    @Published var claudeBackend: ClaudeBackend { didSet { d.set(claudeBackend.rawValue, forKey: "claudeBackend") } }
    @Published var claudeInNotch: Bool { didSet { d.set(claudeInNotch, forKey: "claudeInNotch") } }
    @Published var claudeDoneNotice: Bool { didSet { d.set(claudeDoneNotice, forKey: "claudeDoneNotice") } }
    @Published var claudeSound: Bool { didSet { d.set(claudeSound, forKey: "claudeSound") } }

    /// The app's own language: "system", "en" or "ru". Applied on the next launch through AppleLanguages.
    @Published var appLanguage: String {
        didSet {
            d.set(appLanguage, forKey: "appLanguage")
            if appLanguage == "system" { d.removeObject(forKey: "AppleLanguages") } else { d.set([appLanguage], forKey: "AppleLanguages") }
        }
    }

    // Keep Awake
    /// Seconds; 0 is stored for "until turned off".
    @Published var keepAwakeDefaultDuration: TimeInterval? {
        didSet { d.set(keepAwakeDefaultDuration ?? 0, forKey: "keepAwakeDefaultDuration") }
    }
    @Published var keepAwakeAllowDisplaySleep: Bool {
        didSet { d.set(keepAwakeAllowDisplaySleep, forKey: "keepAwakeAllowDisplaySleep") }
    }
    @Published var keepAwakeIndicator: Bool { didSet { d.set(keepAwakeIndicator, forKey: "keepAwakeIndicator") } }

    private init() {
        d.register(defaults: [
            "savePasswordsToHistory": false,
            "historyLimit": 500,
            "screenshotToast": true,
            "showPlayingInNotch": true,
            "panelStyle": PanelStyle.tinted.rawValue,
            "glassTint": 0.38,
            "panelSize": PanelSize.standard.rawValue,
            "hideInFullScreen": true,
            "keepAwakeDefaultDuration": 0.0,
            "keepAwakeAllowDisplaySleep": false,
            "keepAwakeIndicator": true,
            "batteryNotices": true,
            "claudeInNotch": true,
            "claudeDoneNotice": true,
            "claudeSound": true,
            "appLanguage": "system",
            "badgeTimer": true,
            "hideBadgesInFullScreen": true,
            "noticeTextCapture": true,
            "noticeColor": true,
            "noticeKeepAwake": true,
            "noticeTimer": true,
            "noticeClaudeNeedsYou": true,
            "toastDuration": 2.0,
            "soundTimer": "Glass",
            "prefillFromClipboard": true,
            "showMenuBarIcon": true,
        ])
        savePasswordsToHistory = d.bool(forKey: "savePasswordsToHistory")
        historyLimit = d.integer(forKey: "historyLimit")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        watchedFolders = d.stringArray(forKey: "watchedFolders") ?? [downloads]
        screenshotToast = d.bool(forKey: "screenshotToast")
        showPlayingInNotch = d.bool(forKey: "showPlayingInNotch")
        panelStyle = PanelStyle(rawValue: d.string(forKey: "panelStyle") ?? "") ?? .tinted
        glassTint = d.double(forKey: "glassTint")
        panelSize = PanelSize(rawValue: d.string(forKey: "panelSize") ?? "") ?? .standard
        hideInFullScreen = d.bool(forKey: "hideInFullScreen")
        let awake = d.double(forKey: "keepAwakeDefaultDuration")
        keepAwakeDefaultDuration = awake > 0 ? awake : nil
        keepAwakeAllowDisplaySleep = d.bool(forKey: "keepAwakeAllowDisplaySleep")
        keepAwakeIndicator = d.bool(forKey: "keepAwakeIndicator")
        batteryNotices = d.bool(forKey: "batteryNotices")
        hiddenTabs = d.stringArray(forKey: "hiddenTabs") ?? []
        // Earlier versions only had the API, so a saved key keeps working as before
        let storedBackend = d.persistentDomain(forName: AppPaths.bundleId)?["claudeBackend"] as? String
        claudeBackend = ClaudeBackend(rawValue: storedBackend ?? "")
            ?? (ClaudeAPI.shared.hasAPIKey ? .apiKey : .claudeCode)
        claudeInNotch = d.bool(forKey: "claudeInNotch")
        claudeDoneNotice = d.bool(forKey: "claudeDoneNotice")
        claudeSound = d.bool(forKey: "claudeSound")
        appLanguage = d.string(forKey: "appLanguage") ?? "system"
        badgeTimer = d.bool(forKey: "badgeTimer")
        hideBadgesInFullScreen = d.bool(forKey: "hideBadgesInFullScreen")
        noticeTextCapture = d.bool(forKey: "noticeTextCapture")
        noticeColor = d.bool(forKey: "noticeColor")
        noticeKeepAwake = d.bool(forKey: "noticeKeepAwake")
        noticeTimer = d.bool(forKey: "noticeTimer")
        // Earlier versions had one switch for both battery notices and one for the Claude sound
        noticeCharging = d.object(forKey: "noticeCharging") as? Bool ?? d.bool(forKey: "batteryNotices")
        noticeLowBattery = d.object(forKey: "noticeLowBattery") as? Bool ?? d.bool(forKey: "batteryNotices")
        noticeClaudeNeedsYou = d.bool(forKey: "noticeClaudeNeedsYou")
        toastDuration = d.double(forKey: "toastDuration")
        soundClaudeNeedsYou = d.string(forKey: "soundClaudeNeedsYou") ?? (d.bool(forKey: "claudeSound") ? "Ping" : "")
        soundTimer = d.string(forKey: "soundTimer") ?? "Glass"
        prefillFromClipboard = d.bool(forKey: "prefillFromClipboard")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
    }
}
