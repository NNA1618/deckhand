import AppKit
import Carbon.HIToolbox
import Combine

/// A shortcut in Carbon terms: key code and modifier mask.
/// Key codes are physical keys, so a shortcut works the same with any keyboard layout.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
    /// The four modifiers a shortcut may use. Anything else (caps lock, fn) is dropped.
    static let modifierMask = command | shift | option | control

    /// Modifiers in the order macOS menus show them: ⌃⌥⇧⌘.
    var modifierSymbols: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s
    }

    /// For menus, Home and Settings, with the key named in the app's language («⌃⌥Пробел»).
    var display: String { modifierSymbols + KeyNames.name(for: keyCode) }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init(_ keyCode: Int, _ modifiers: UInt32) {
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var m: UInt32 = 0
        if flags.contains(.command) { m |= Self.command }
        if flags.contains(.shift) { m |= Self.shift }
        if flags.contains(.option) { m |= Self.option }
        if flags.contains(.control) { m |= Self.control }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    var isFunctionKey: Bool { KeyNames.functionKeyNumber(keyCode) != nil }
}

enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case toggle
    case screenshot, captureWindow, captureScreen, captureDelayed, captureAndEdit, captureText, colorPicker
    case keepAwake, translateSelection
    case clipboard, translator, claude, prompts, media, shelf, recents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: return String(localized: "Open or close Deckhand")
        case .screenshot: return String(localized: "Capture an area")
        case .captureWindow: return String(localized: "Capture a window")
        case .captureScreen: return String(localized: "Capture the whole screen")
        case .captureDelayed: return String(localized: "Capture the screen in 3 seconds")
        case .captureAndEdit: return String(localized: "Capture an area and edit")
        case .captureText: return String(localized: "Copy text from the screen")
        case .colorPicker: return String(localized: "Pick a color on the screen")
        case .keepAwake: return String(localized: "Turn Keep Awake on or off")
        case .translateSelection: return String(localized: "Translate selected text")
        case .clipboard: return String(localized: "Clipboard")
        case .translator: return String(localized: "Translate")
        case .claude: return String(localized: "Claude")
        case .prompts: return String(localized: "Prompts")
        case .media: return String(localized: "Music")
        case .shelf: return String(localized: "Shelf")
        case .recents: return String(localized: "Recents")
        }
    }

    /// The panel tab a shortcut opens, for the tab-opening actions.
    var tab: NotchTab? {
        switch self {
        case .clipboard: return .clipboard
        case .translator: return .translator
        case .claude: return .claude
        case .prompts: return .prompts
        case .media: return .media
        case .shelf: return .shelf
        case .recents: return .recents
        default: return nil
        }
    }

    /// Deckhand's own family: ⌃⌥⇧ plus a letter. macOS uses none of these, Rectangle and Magnet
    /// stop at ⌃⌥, and apps rarely put three modifiers on a menu item. ⌃⌥Space (the system
    /// "Select next input source") and ⇧⌘ letters (Save As, Duplicate) are deliberately avoided.
    /// The extra capture modes start without a shortcut so Deckhand doesn't claim more keys than needed.
    var defaultShortcut: Shortcut? {
        let family = Shortcut.control | Shortcut.option | Shortcut.shift
        switch self {
        case .toggle: return Shortcut(kVK_ANSI_D, family)
        case .screenshot: return Shortcut(kVK_ANSI_S, family)
        case .captureText: return Shortcut(kVK_ANSI_E, family)
        case .colorPicker: return Shortcut(kVK_ANSI_C, family)
        case .keepAwake: return Shortcut(kVK_ANSI_A, family)
        case .translateSelection: return Shortcut(kVK_ANSI_T, family)
        case .clipboard: return Shortcut(kVK_ANSI_V, family)
        case .translator: return Shortcut(kVK_ANSI_L, family)
        case .claude: return Shortcut(kVK_ANSI_K, family)
        case .prompts: return Shortcut(kVK_ANSI_P, family)
        case .media: return Shortcut(kVK_ANSI_M, family)
        case .shelf: return Shortcut(kVK_ANSI_F, family)
        case .recents: return Shortcut(kVK_ANSI_H, family)
        case .captureWindow, .captureScreen, .captureDelayed, .captureAndEdit: return nil
        }
    }

    /// The defaults of 0.4 and earlier. Only users who still have exactly these get the new ones.
    var legacyDefaultShortcut: Shortcut? {
        let ctrlOpt = Shortcut.control | Shortcut.option
        switch self {
        case .toggle: return Shortcut(kVK_Space, ctrlOpt)
        case .screenshot: return Shortcut(kVK_ANSI_S, Shortcut.command | Shortcut.shift)
        case .captureText: return Shortcut(kVK_ANSI_E, Shortcut.command | Shortcut.shift)
        case .colorPicker: return Shortcut(kVK_ANSI_C, ctrlOpt)
        case .keepAwake: return Shortcut(kVK_ANSI_A, ctrlOpt)
        case .translateSelection: return Shortcut(kVK_ANSI_T, ctrlOpt | Shortcut.shift)
        case .clipboard: return Shortcut(kVK_ANSI_V, ctrlOpt)
        case .translator: return Shortcut(kVK_ANSI_T, ctrlOpt)
        case .claude: return Shortcut(kVK_ANSI_K, ctrlOpt)
        case .prompts: return Shortcut(kVK_ANSI_P, ctrlOpt)
        case .media: return Shortcut(kVK_ANSI_M, ctrlOpt)
        case .shelf: return Shortcut(kVK_ANSI_F, ctrlOpt)
        case .recents: return Shortcut(kVK_ANSI_H, ctrlOpt)
        case .captureWindow, .captureScreen, .captureDelayed, .captureAndEdit: return nil
        }
    }
}

/// Registers global shortcuts through Carbon (no Accessibility permission needed),
/// stores assignments and reports conflicts.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var shortcuts: [HotkeyAction: Shortcut] = [:]
    /// Why an action's shortcut may not work or may take keys from other apps.
    @Published private(set) var conflicts: [HotkeyAction: ShortcutConflict] = [:]
    /// The last time setting a shortcut took it away from another action, for "Removed from …".
    @Published private(set) var lastMove: (to: HotkeyAction, from: HotkeyAction)?

    private var handlers: [HotkeyAction: @MainActor () -> Void] = [:]
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false
    private let storeKey = "hotkeys"
    private let versionKey = "hotkeysVersion"
    /// 2: the ⌃⌥⇧ family of 0.5.
    private static let currentVersion = 2

    private init() {
        let defaults = UserDefaults.standard
        var saved: [String: Shortcut?]?
        if let data = defaults.data(forKey: storeKey) {
            saved = try? JSONDecoder().decode([String: Shortcut?].self, from: data)
        }
        var stored = saved ?? [:]
        let needsMigration = saved != nil && defaults.integer(forKey: versionKey) < Self.currentVersion
        if needsMigration {
            stored = HotkeyMigration.migrate(stored)
        }
        shortcuts = HotkeyMigration.resolve(stored)
        if needsMigration {
            save()
            Log.info("hotkeys migrated to the 0.5 defaults where they were unchanged")
        }
        installHandler()
    }

    func setHandler(_ action: HotkeyAction, _ handler: @escaping @MainActor () -> Void) {
        handlers[action] = handler
    }

    /// The shortcut if it is registered right now. Menus and Home show this one, so they never
    /// advertise a shortcut that failed to register.
    func activeShortcut(for action: HotkeyAction) -> Shortcut? {
        refs[action] != nil || suspended ? shortcuts[action] : nil
    }

    /// A new shortcut, or nil to remove it. Taking a shortcut from another action is reported in `lastMove`.
    func set(_ shortcut: Shortcut?, for action: HotkeyAction) {
        lastMove = nil
        if let shortcut {
            for (other, sc) in shortcuts where other != action && sc == shortcut {
                shortcuts[other] = nil
                lastMove = (action, other)
            }
        }
        shortcuts[action] = shortcut
        save()
        if !suspended { registerAll() } else { refreshConflicts() }
    }

    func resetToDefaults() {
        lastMove = nil
        var fresh: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases { fresh[action] = action.defaultShortcut }
        shortcuts = fresh
        save()
        registerAll()
    }

    func registerAll() {
        unregisterAll()
        suspended = false
        var failed: Set<HotkeyAction> = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let sc = shortcuts[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x444B4844), id: UInt32(index + 1)) // 'DKHD'
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                failed.insert(action)
                Log.info("hotkey \(action.rawValue) \(sc.display) failed: status=\(status)")
            }
        }
        refreshConflicts(failed: failed)
    }

    /// Shortcuts are unregistered while recording, otherwise they would swallow the key press.
    func suspend() {
        unregisterAll()
        suspended = true
    }

    private func refreshConflicts(failed: Set<HotkeyAction> = []) {
        let system = SymbolicHotKeys.current()
        let apps = KnownAppShortcuts.installed()
        var found: [HotkeyAction: ShortcutConflict] = [:]
        for (action, sc) in shortcuts {
            if let conflict = ShortcutConflict.find(for: sc, system: system, apps: apps) {
                found[action] = conflict
            } else if failed.contains(action) {
                found[action] = .registrationFailed
            }
        }
        if found != conflicts {
            for (action, conflict) in found { Log.info("hotkey \(action.rawValue) conflict: \(conflict.logName)") }
        }
        conflicts = found
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    /// Stores every action, with the format version so the migration runs only once.
    /// A snapshot run shares the user's preferences domain, so it never writes.
    private func save() {
        guard !AppPaths.isSnapshot else { return }
        var dict: [String: Shortcut?] = [:]
        for action in HotkeyAction.allCases { dict[action.rawValue] = shortcuts[action] }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storeKey)
            UserDefaults.standard.set(Self.currentVersion, forKey: versionKey)
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

/// Moves users from the 0.4 defaults to the 0.5 family, leaving every shortcut they chose alone.
enum HotkeyMigration {
    /// `stored` maps action names to a shortcut, or to nil when the user removed it.
    /// A missing key means "never touched", which already gets the new default.
    static func migrate(_ stored: [String: Shortcut?]) -> [String: Shortcut?] {
        var result = stored
        var migrated: [HotkeyAction] = []
        for action in HotkeyAction.allCases {
            guard let entry = stored[action.rawValue], let current = entry,
                  current == action.legacyDefaultShortcut, current != action.defaultShortcut else { continue }
            result[action.rawValue] = .some(action.defaultShortcut)
            migrated.append(action)
        }
        // If the user already gave a new default to some other action, the migrated one keeps its old keys
        for action in migrated {
            guard let new = action.defaultShortcut else { continue }
            let takenByKept = HotkeyAction.allCases.contains { other in
                other != action && !migrated.contains(other) && (result[other.rawValue] ?? other.defaultShortcut) == new
            }
            if takenByKept { result[action.rawValue] = .some(action.legacyDefaultShortcut) }
        }
        return result
    }

    /// The shortcuts to use for a stored dictionary. An action missing from it (one added in a
    /// later version, like `translateSelection` for a 0.4 store) gets its default, unless a stored
    /// shortcut already uses those keys: then it starts without one rather than duplicating it.
    static func resolve(_ stored: [String: Shortcut?]) -> [HotkeyAction: Shortcut] {
        let taken = Set(stored.values.compactMap { $0 })
        var loaded: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            if let entry = stored[action.rawValue] {
                if let sc = entry { loaded[action] = sc }
            } else if let sc = action.defaultShortcut, !taken.contains(sc) {
                loaded[action] = sc
            }
        }
        return loaded
    }
}

/// What the recorder accepts.
enum ShortcutRules {
    enum Verdict: Equatable {
        case ok
        /// No ⌘ or ⌃: it would fire while typing (⌥ letters type accents and symbols).
        case needsModifier
        /// macOS or every app relies on it.
        case reserved
    }

    /// ⌘Q ⌘W ⌘H ⌘M ⌘C ⌘V ⌘X ⌘Z ⌘A ⌘Tab ⌘Space ⌃Space.
    static let reserved: Set<Shortcut> = {
        let cmd = Shortcut.command
        let keys = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_C, kVK_ANSI_V,
                    kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_Tab, kVK_Space]
        var set = Set(keys.map { Shortcut($0, cmd) })
        set.insert(Shortcut(kVK_Space, Shortcut.control))
        return set
    }()

    static func verdict(for sc: Shortcut) -> Verdict {
        if reserved.contains(sc) { return .reserved }
        // Function keys type nothing, so they may be used alone or with any modifier
        if sc.isFunctionKey { return .ok }
        if sc.modifiers & (Shortcut.command | Shortcut.control) == 0 { return .needsModifier }
        return .ok
    }

    /// Esc, Delete and Return without modifiers drive the recorder itself.
    static func isModifierOnly(keyCode: UInt16) -> Bool {
        [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
         kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function].contains(Int(keyCode))
    }
}

/// A reason a shortcut may not work, or may take keys from someone else.
enum ShortcutConflict: Equatable {
    /// An enabled macOS shortcut, with its name when Deckhand knows it.
    case system(name: String?)
    /// An installed app known to use it by default.
    case app(name: String)
    /// ⇧⌘ plus a letter: menus in many apps (Save As, Duplicate, Show Explorer).
    case manyApps
    /// Carbon refused to register it: another app holds it.
    case registrationFailed

    /// Orange caption under the recorder.
    var message: String {
        switch self {
        case .system(let name?): return String(localized: "macOS uses this shortcut: “\(name)”.")
        case .system(nil): return String(localized: "macOS uses this shortcut.")
        case .app(let name): return String(localized: "\(name) uses this shortcut.")
        case .manyApps: return String(localized: "Many apps use this shortcut. Deckhand will take it from them.")
        case .registrationFailed: return String(localized: "Taken by another app or macOS.")
        }
    }

    var logName: String {
        switch self {
        case .system(let name): return "system \(name ?? "?")"
        case .app(let name): return "app \(name)"
        case .manyApps: return "many apps"
        case .registrationFailed: return "registration failed"
        }
    }

    /// The most important conflict for a shortcut: macOS first, then known apps, then the ⇧⌘ warning.
    static func find(for sc: Shortcut, system: [SymbolicHotKeys.Entry], apps: [KnownAppShortcuts.App]) -> ShortcutConflict? {
        if system.contains(where: { $0.matches(sc) }) {
            return .system(name: SymbolicHotKeys.name(for: sc))
        }
        if let app = apps.first(where: { $0.shortcuts.contains(sc) }) {
            return .app(name: app.name)
        }
        if sc.modifiers == Shortcut.command | Shortcut.shift, KeyNames.isLetter(sc.keyCode) {
            return .manyApps
        }
        return nil
    }
}

/// The macOS shortcuts in System Settings → Keyboard → Keyboard Shortcuts that are turned on.
enum SymbolicHotKeys {
    struct Entry: Equatable {
        var keyCode: UInt32
        /// Carbon modifiers, possibly with the fn bit.
        var modifiers: UInt32

        static let fnBit: UInt32 = 1 << 17

        /// Arrows and function keys carry the fn bit by nature; anywhere else it means the
        /// shortcut needs the fn/Globe key, which a Deckhand shortcut never has.
        func matches(_ sc: Shortcut) -> Bool {
            guard keyCode == sc.keyCode else { return false }
            if modifiers & Self.fnBit != 0 && !KeyNames.carriesFn(keyCode) { return false }
            return modifiers & Shortcut.modifierMask == sc.modifiers
        }
    }

    static func current() -> [Entry] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard (dict[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = dict[kHISymbolicHotKeyCode as String] as? Int, code != 0xFFFF,
                  let mods = dict[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            return Entry(keyCode: UInt32(code), modifiers: UInt32(mods))
        }
    }

    /// Names for the macOS shortcuts people most often run into. The API gives no names.
    static func name(for sc: Shortcut) -> String? {
        let c = Shortcut.control, o = Shortcut.option, s = Shortcut.shift, m = Shortcut.command
        switch (Int(sc.keyCode), sc.modifiers) {
        case (kVK_Space, c | o): return String(localized: "Select next input source")
        case (kVK_Space, c): return String(localized: "Select the previous input source")
        case (kVK_Space, m): return String(localized: "Spotlight")
        case (kVK_Space, o | m): return String(localized: "Finder search window")
        case (kVK_Space, c | m): return String(localized: "Emoji & Symbols")
        case (kVK_ANSI_3, s | m), (kVK_ANSI_4, s | m), (kVK_ANSI_5, s | m),
             (kVK_ANSI_3, c | s | m), (kVK_ANSI_4, c | s | m):
            return String(localized: "Screenshots")
        case (kVK_UpArrow, c), (kVK_DownArrow, c), (kVK_LeftArrow, c), (kVK_RightArrow, c):
            return String(localized: "Mission Control")
        default: return nil
        }
    }
}

/// Default shortcuts of popular apps that take keys globally. Checked only for apps that are installed.
enum KnownAppShortcuts {
    struct App {
        var bundleIds: [String]
        var name: String
        var shortcuts: Set<Shortcut>
    }

    static let all: [App] = {
        let co = Shortcut.control | Shortcut.option
        // Rectangle and Magnet: halves, corners, thirds, maximize, center, restore, larger/smaller
        let windowKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Return,
                          kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K,
                          kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_E, kVK_ANSI_T,
                          kVK_ANSI_C, kVK_Delete, kVK_ANSI_Minus, kVK_ANSI_Equal]
        var window = Set(windowKeys.map { Shortcut($0, co) })
        window.insert(Shortcut(kVK_LeftArrow, co | Shortcut.command))
        window.insert(Shortcut(kVK_RightArrow, co | Shortcut.command))
        window.insert(Shortcut(kVK_UpArrow, co | Shortcut.shift))
        let optSpace: Set = [Shortcut(kVK_Space, Shortcut.option)]
        return [
            App(bundleIds: ["com.knollsoft.Rectangle", "com.knollsoft.Hookshot"], name: "Rectangle", shortcuts: window),
            App(bundleIds: ["id.arunvaradarajan.Magnet", "com.crowdcafe.windowmagnet"], name: "Magnet", shortcuts: window),
            App(bundleIds: ["com.raycast.macos"], name: "Raycast", shortcuts: optSpace),
            App(bundleIds: ["com.runningwithcrayons.Alfred"], name: "Alfred", shortcuts: optSpace),
            App(bundleIds: ["com.culturedcode.ThingsMac"], name: "Things", shortcuts: [Shortcut(kVK_Space, co)]),
            App(bundleIds: ["com.1password.1password"], name: "1Password",
                shortcuts: [Shortcut(kVK_Space, Shortcut.command | Shortcut.shift), Shortcut(kVK_ANSI_Backslash, Shortcut.command)]),
            App(bundleIds: ["org.p0deje.Maccy"], name: "Maccy", shortcuts: [Shortcut(kVK_ANSI_C, Shortcut.command | Shortcut.shift)]),
            App(bundleIds: ["pl.maketheweb.cleanshotx"], name: "CleanShot X",
                shortcuts: [Shortcut(kVK_ANSI_3, Shortcut.command | Shortcut.shift), Shortcut(kVK_ANSI_4, Shortcut.command | Shortcut.shift),
                            Shortcut(kVK_ANSI_5, Shortcut.command | Shortcut.shift)]),
        ]
    }()

    @MainActor private static var cache: (time: Date, apps: [App])?

    /// Launch Services lookups are cheap but not free, so the answer is kept for a minute.
    @MainActor
    static func installed() -> [App] {
        if let cache, Date().timeIntervalSince(cache.time) < 60 { return cache.apps }
        let ws = NSWorkspace.shared
        let apps = all.filter { app in app.bundleIds.contains { ws.urlForApplication(withBundleIdentifier: $0) != nil } }
        cache = (Date(), apps)
        return apps
    }
}

/// Key names for display. Letters come from the current ASCII-capable layout (so «S», not «Ы»,
/// with the Russian layout on); named keys are translated.
enum KeyNames {
    static func name(for keyCode: UInt32) -> String {
        if let f = functionKeyNumber(keyCode) { return "F\(f)" }
        switch Int(keyCode) {
        case kVK_Space: return String(localized: "Space")
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌅"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "?"
    }

    static func functionKeyNumber(_ keyCode: UInt32) -> Int? { fKeys[Int(keyCode)] }

    /// Keys whose events always carry the fn bit.
    static func carriesFn(_ keyCode: UInt32) -> Bool {
        functionKeyNumber(keyCode) != nil || [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help].contains(Int(keyCode))
    }

    /// Letter keys by physical position (ANSI), independent of the layout.
    static func isLetter(_ keyCode: UInt32) -> Bool { letterKeys.contains(Int(keyCode)) }

    private static let letterKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
        kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
    ]

    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
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
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private static let fKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
        kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
        kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]
}
