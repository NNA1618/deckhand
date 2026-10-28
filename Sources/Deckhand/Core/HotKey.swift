import AppKit
import Carbon.HIToolbox
import Combine

/// A shortcut in Carbon terms: key code and modifier mask.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        // Without ⌘, ⌥ or ⌃ a global shortcut would break normal typing
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case toggle, screenshot, clipboard, translator, claude, prompts, media, shelf, recents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: return String(localized: "Open or close Deckhand")
        case .screenshot: return String(localized: "Capture area to clipboard")
        case .clipboard: return String(localized: "Clipboard")
        case .translator: return String(localized: "Translate")
        case .claude: return String(localized: "Claude")
        case .prompts: return String(localized: "Prompts")
        case .media: return String(localized: "Music")
        case .shelf: return String(localized: "Shelf")
        case .recents: return String(localized: "Recents")
        }
    }

    var defaultShortcut: Shortcut {
        let ctrlOpt = UInt32(controlKey | optionKey)
        switch self {
        case .toggle: return Shortcut(keyCode: UInt32(kVK_Space), modifiers: ctrlOpt)
        case .screenshot: return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        case .clipboard: return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: ctrlOpt)
        case .translator: return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: ctrlOpt)
        case .claude: return Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: ctrlOpt)
        case .prompts: return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt)
        case .media: return Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: ctrlOpt)
        case .shelf: return Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: ctrlOpt)
        case .recents: return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: ctrlOpt)
        }
    }
}

/// Registers global shortcuts through Carbon (no Accessibility permission needed),
/// stores assignments and reports conflicts.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var shortcuts: [HotkeyAction: Shortcut] = [:]
    /// Actions whose shortcut is already taken by another app.
    @Published private(set) var conflicts: Set<HotkeyAction> = []

    private var handlers: [HotkeyAction: @MainActor () -> Void] = [:]
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let storeKey = "hotkeys"

    private init() {
        var loaded: [HotkeyAction: Shortcut] = [:]
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            for action in HotkeyAction.allCases {
                if let entry = saved[action.rawValue] {
                    if let sc = entry { loaded[action] = sc }
                } else {
                    loaded[action] = action.defaultShortcut
                }
            }
        } else {
            for action in HotkeyAction.allCases { loaded[action] = action.defaultShortcut }
        }
        shortcuts = loaded
        installHandler()
    }

    func setHandler(_ action: HotkeyAction, _ handler: @escaping @MainActor () -> Void) {
        handlers[action] = handler
    }

    /// A new shortcut, or nil to remove it.
    func set(_ shortcut: Shortcut?, for action: HotkeyAction) {
        if let shortcut {
            // Take the same shortcut away from any other action
            for (other, sc) in shortcuts where other != action && sc == shortcut {
                shortcuts[other] = nil
            }
        }
        shortcuts[action] = shortcut
        save()
        registerAll()
    }

    func resetToDefaults() {
        for action in HotkeyAction.allCases { shortcuts[action] = action.defaultShortcut }
        save()
        registerAll()
    }

    func registerAll() {
        unregisterAll()
        var newConflicts: Set<HotkeyAction> = []
        for action in HotkeyAction.allCases {
            guard let sc = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x444B4844), id: UInt32(HotkeyAction.allCases.firstIndex(of: action)! + 1)) // 'DKHD'
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                newConflicts.insert(action)
            }
            Log.info("hotkey \(action.rawValue) \(sc.display): status=\(status)")
        }
        conflicts = newConflicts
    }

    /// Shortcuts are unregistered while recording, otherwise they would swallow the key press.
    func suspend() { unregisterAll() }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func save() {
        var dict: [String: Shortcut?] = [:]
        for action in HotkeyAction.allCases { dict[action.rawValue] = shortcuts[action] }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    fileprivate func fire(index: UInt32) {
        let all = HotkeyAction.allCases
        guard index >= 1, Int(index) <= all.count else { return }
        handlers[all[Int(index) - 1]]?()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                guard status == noErr, hkID.signature == OSType(0x444B4844) else { return OSStatus(eventNotHandledErr) }
                let index = hkID.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyManager.shared.fire(index: index) } }
                return noErr
            },
            1, &eventType, nil, &eventHandler
        )
    }
}

/// Key name for a key code in the current keyboard layout.
enum KeyNames {
    static func name(for keyCode: UInt32) -> String {
        if let f = fKeys[Int(keyCode)] { return "F\(f)" }
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let fKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
        kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
        kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]
}
