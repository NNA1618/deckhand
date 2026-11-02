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
    @Published var claudeInstructions: String { didSet { d.set(claudeInstructions, forKey: "claudeInstructions") } }
    @Published var watchedFolders: [String] { didSet { d.set(watchedFolders, forKey: "watchedFolders") } }
    @Published var screenshotToast: Bool { didSet { d.set(screenshotToast, forKey: "screenshotToast") } }
    @Published var showPlayingInNotch: Bool { didSet { d.set(showPlayingInNotch, forKey: "showPlayingInNotch") } }

    // Appearance and panel behaviour
    @Published var panelStyle: PanelStyle { didSet { d.set(panelStyle.rawValue, forKey: "panelStyle") } }
    /// Darkness of the glass tint, 0...0.8.
    @Published var glassTint: Double { didSet { d.set(glassTint, forKey: "glassTint") } }
    @Published var panelSize: PanelSize { didSet { d.set(panelSize.rawValue, forKey: "panelSize") } }
    @Published var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "openOnHover") } }
    /// Seconds the pointer must rest on the notch before the panel opens.
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var hideInFullScreen: Bool { didSet { d.set(hideInFullScreen, forKey: "hideInFullScreen") } }

    @Published var batteryNotices: Bool { didSet { d.set(batteryNotices, forKey: "batteryNotices") } }

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
            "openOnHover": true,
            "hoverDelay": 0.08,
            "hideInFullScreen": true,
            "keepAwakeDefaultDuration": 0.0,
            "keepAwakeAllowDisplaySleep": false,
            "keepAwakeIndicator": true,
            "batteryNotices": true,
        ])
        savePasswordsToHistory = d.bool(forKey: "savePasswordsToHistory")
        historyLimit = d.integer(forKey: "historyLimit")
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        claudeInstructions = d.string(forKey: "claudeInstructions") ?? ""
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        watchedFolders = d.stringArray(forKey: "watchedFolders") ?? [downloads]
        screenshotToast = d.bool(forKey: "screenshotToast")
        showPlayingInNotch = d.bool(forKey: "showPlayingInNotch")
        panelStyle = PanelStyle(rawValue: d.string(forKey: "panelStyle") ?? "") ?? .tinted
        glassTint = d.double(forKey: "glassTint")
        panelSize = PanelSize(rawValue: d.string(forKey: "panelSize") ?? "") ?? .standard
        openOnHover = d.bool(forKey: "openOnHover")
        hoverDelay = d.double(forKey: "hoverDelay")
        hideInFullScreen = d.bool(forKey: "hideInFullScreen")
        let awake = d.double(forKey: "keepAwakeDefaultDuration")
        keepAwakeDefaultDuration = awake > 0 ? awake : nil
        keepAwakeAllowDisplaySleep = d.bool(forKey: "keepAwakeAllowDisplaySleep")
        keepAwakeIndicator = d.bool(forKey: "keepAwakeIndicator")
        batteryNotices = d.bool(forKey: "batteryNotices")
    }
}
