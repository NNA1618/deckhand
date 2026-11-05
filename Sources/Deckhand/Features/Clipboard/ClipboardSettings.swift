import Foundation

/// Clipboard settings added in 0.5. The older ones (`historyLimit`, `savePasswordsToHistory`,
/// `excludedApps`) stay in `Settings` so existing users keep their values.
@MainActor
final class ClipboardSettings: ObservableObject {
    static let shared = ClipboardSettings()
    private let d = UserDefaults.standard

    /// Off: nothing new is saved. The history already saved stays.
    @Published var recordHistory: Bool { didSet { d.set(recordHistory, forKey: "clipboardRecordHistory") } }
    /// 0 means forever.
    @Published var historyMaxAgeDays: Int { didSet { d.set(historyMaxAgeDays, forKey: "historyMaxAgeDays") } }
    @Published var saveImages: Bool { didSet { d.set(saveImages, forKey: "clipboardSaveImages") } }
    /// 0 means no limit.
    @Published var maxImageMB: Int { didSet { d.set(maxImageMB, forKey: "clipboardMaxImageMB") } }
    @Published var saveFiles: Bool { didSet { d.set(saveFiles, forKey: "clipboardSaveFiles") } }
    /// Return and double-click paste into the app you were using; off: they only copy.
    @Published var pasteOnSelect: Bool { didSet { d.set(pasteOnSelect, forKey: "clipboardPasteOnSelect") } }

    /// Decimal megabytes, as Finder and the menu show them.
    var maxImageBytes: Int { maxImageMB * 1_000_000 }

    private init() {
        d.register(defaults: [
            "clipboardRecordHistory": true,
            "historyMaxAgeDays": 0,
            "clipboardSaveImages": true,
            "clipboardMaxImageMB": 0,
            "clipboardSaveFiles": true,
            "clipboardPasteOnSelect": true,
        ])
        recordHistory = d.bool(forKey: "clipboardRecordHistory")
        historyMaxAgeDays = d.integer(forKey: "historyMaxAgeDays")
        saveImages = d.bool(forKey: "clipboardSaveImages")
        maxImageMB = d.integer(forKey: "clipboardMaxImageMB")
        saveFiles = d.bool(forKey: "clipboardSaveFiles")
        pasteOnSelect = d.bool(forKey: "clipboardPasteOnSelect")
    }
}
