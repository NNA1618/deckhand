import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the text selected in the app the user is working in, for "Translate selected text".
///
/// It asks the focused element for its selected text through Accessibility first, which leaves the
/// clipboard alone. Apps that don't answer (many web views and Electron apps) get a simulated ⌘C,
/// and the clipboard is put back the way it was right after.
@MainActor
enum SelectionReader {
    enum Result: Equatable {
        case selection(String)
        /// Nothing was selected: the clipboard text, if any.
        case clipboard(String?)
        /// Accessibility isn't allowed, so only the clipboard could be read.
        case noPermission(clipboard: String?)
    }

    static func read() async -> Result {
        let clipboard = NSPasteboard.general.prefillText
        guard AXIsProcessTrusted() else { return .noPermission(clipboard: clipboard) }
        if let text = await Task.detached(priority: .userInitiated, operation: { selectedTextOfFocusedElement() }).value {
            return .selection(text)
        }
        if let text = await copySelection() { return .selection(text) }
        return .clipboard(clipboard)
    }

    // MARK: - Accessibility

    nonisolated private static func selectedTextOfFocusedElement() -> String? {
        let system = AXUIElementCreateSystemWide()
        // A busy app must not hold up the shortcut
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var pid: pid_t = 0
        // Deckhand's own panel or Settings: there is no selection in another app to read
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - ⌘C

    private static func copySelection() async -> String? {
        // The ⌘C and the restore are Deckhand's, not the user's copies: keep them out of the history
        let watcher = ClipboardWatcher.shared
        watcher.suspendCapture()
        defer { watcher.resumeCapture() }
        let pb = NSPasteboard.general
        let name = pb.name
        // Reading every type can make the app that copied render it now (a large image, say),
        // so it happens off the main thread
        let saved = await Task.detached(priority: .userInitiated) {
            PasteboardContents.save(NSPasteboard(name: name))
        }.value
        let before = pb.changeCount
        // The shortcut's own keys are usually still down; ⌘C with ⌃⌥⇧ held means something else
        await waitForModifierKeysUp()
        PasteService.postCommandShortcut("c", fallback: kVK_ANSI_C)
        for _ in 0..<30 where pb.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.restore(to: pb)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func waitForModifierKeysUp() async {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<40 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A copy of the clipboard, to put it back after reading the selection with ⌘C.
struct PasteboardContents: Sendable {
    struct Entry: Sendable {
        let type: String
        let data: Data
    }

    let items: [[Entry]]
    /// False for a password or another copy meant to vanish: putting it back would change the
    /// change count, and password managers then no longer clear it. The selection stays instead.
    let restores: Bool

    /// Promised files: reading these makes the app that copied write the file out.
    nonisolated static let promiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "NSPromiseContentsPboardType",
        "Apple files promise pasteboard type",
    ]

    /// Reads what can be put back. Safe off the main thread; a password is not read at all.
    nonisolated static func save(_ pb: NSPasteboard) -> PasteboardContents {
        let types = Set((pb.types ?? []).map(\.rawValue))
        if ClipboardWatcher.isPassword(types: types, sourceApp: nil) {
            return PasteboardContents(items: [], restores: false)
        }
        let items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> Entry? in
                guard !promiseTypes.contains(type.rawValue), let data = item.data(forType: type) else { return nil }
                return Entry(type: type.rawValue, data: data)
            }
        }
        return PasteboardContents(items: items.filter { !$0.isEmpty }, restores: true)
    }

    func restore(to pb: NSPasteboard) {
        guard restores else { return }
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type)) }
            return item
        }
        pb.writeObjects(restored)
    }
}
