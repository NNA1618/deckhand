import Foundation
import Combine
import UniformTypeIdentifiers

/// What happens after an area, window or screen capture. Every choice copies the image first.
enum CaptureAfterAction: String, CaseIterable, Identifiable {
    case copy, copyAndEdit, copyAndSave
    var id: String { rawValue }
    var title: String {
        switch self {
        case .copy: return String(localized: "afterCapture.copy", defaultValue: "Copy")
        case .copyAndEdit: return String(localized: "Copy and edit")
        case .copyAndSave: return String(localized: "Copy and save")
        }
    }
}

enum CaptureFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

/// Settings for screenshots, text from the screen, the color picker and the editor.
/// UserDefaults-backed like `Settings`; shown in Settings → Screenshots & Text.
@MainActor
final class CaptureSettings: ObservableObject {
    static let shared = CaptureSettings()
    private let d = UserDefaults.standard

    @Published var afterCapture: CaptureAfterAction { didSet { d.set(afterCapture.rawValue, forKey: "captureAction") } }
    /// Where "Copy and save" and the editor's Save put files.
    @Published var saveFolder: String { didSet { d.set(saveFolder, forKey: "captureFolder") } }
    @Published var format: CaptureFormat { didSet { d.set(format.rawValue, forKey: "captureFormat") } }
    @Published var shutterSound: Bool { didSet { d.set(shutterSound, forKey: "screenshotSound") } }

    /// Vision language codes in priority order.
    @Published var ocrLanguages: [String] { didSet { d.set(ocrLanguages, forKey: "ocrLanguages") } }
    @Published var ocrAutoDetect: Bool { didSet { d.set(ocrAutoDetect, forKey: "ocrAutoDetect") } }
    @Published var ocrLanguageCorrection: Bool { didSet { d.set(ocrLanguageCorrection, forKey: "ocrLanguageCorrection") } }
    @Published var ocrKeepLineBreaks: Bool { didSet { d.set(ocrKeepLineBreaks, forKey: "ocrKeepLineBreaks") } }

    @Published var colorFormat: ColorFormat { didSet { d.set(colorFormat.rawValue, forKey: "colorFormat") } }
    @Published var editorDefaultTool: EditorTool { didSet { d.set(editorDefaultTool.rawValue, forKey: "editorDefaultTool") } }

    /// Whether Deckhand already asked macOS for Screen Recording once (macOS shows its prompt only once).
    var askedForScreenRecording: Bool {
        get { d.bool(forKey: "askedForScreenRecording") }
        set { d.set(newValue, forKey: "askedForScreenRecording") }
    }

    static var defaultFolder: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Desktop"
    }

    private init() {
        d.register(defaults: [
            "captureAction": CaptureAfterAction.copy.rawValue,
            "captureFolder": Self.defaultFolder,
            "captureFormat": CaptureFormat.png.rawValue,
            "screenshotSound": false,
            "ocrLanguages": OCROptions.defaultLanguages(preferred: Locale.preferredLanguages),
            "ocrAutoDetect": false,
            "ocrLanguageCorrection": true,
            "ocrKeepLineBreaks": true,
            "colorFormat": ColorFormat.hexUpper.rawValue,
            "editorDefaultTool": EditorTool.arrow.rawValue,
        ])
        afterCapture = CaptureAfterAction(rawValue: d.string(forKey: "captureAction") ?? "") ?? .copy
        saveFolder = d.string(forKey: "captureFolder") ?? Self.defaultFolder
        format = CaptureFormat(rawValue: d.string(forKey: "captureFormat") ?? "") ?? .png
        shutterSound = d.bool(forKey: "screenshotSound")
        ocrLanguages = d.stringArray(forKey: "ocrLanguages") ?? ["en-US"]
        ocrAutoDetect = d.bool(forKey: "ocrAutoDetect")
        ocrLanguageCorrection = d.bool(forKey: "ocrLanguageCorrection")
        ocrKeepLineBreaks = d.bool(forKey: "ocrKeepLineBreaks")
        colorFormat = ColorFormat(rawValue: d.string(forKey: "colorFormat") ?? "") ?? .hexUpper
        editorDefaultTool = EditorTool(rawValue: d.string(forKey: "editorDefaultTool") ?? "") ?? .arrow
    }

    var saveFolderURL: URL { URL(fileURLWithPath: saveFolder, isDirectory: true) }

    var ocrOptions: OCROptions {
        OCROptions(languages: ocrLanguages, autoDetect: ocrAutoDetect,
                   languageCorrection: ocrLanguageCorrection, keepLineBreaks: ocrKeepLineBreaks)
    }

    func restoreDefaults() {
        for key in ["captureAction", "captureFolder", "captureFormat", "screenshotSound", "ocrLanguages", "ocrAutoDetect",
                    "ocrLanguageCorrection", "ocrKeepLineBreaks", "colorFormat", "editorDefaultTool"] {
            d.removeObject(forKey: key)
        }
        afterCapture = .copy
        saveFolder = Self.defaultFolder
        format = .png
        shutterSound = false
        ocrLanguages = d.stringArray(forKey: "ocrLanguages") ?? ["en-US"]
        ocrAutoDetect = false
        ocrLanguageCorrection = true
        ocrKeepLineBreaks = true
        colorFormat = .hexUpper
        editorDefaultTool = .arrow
    }
}
