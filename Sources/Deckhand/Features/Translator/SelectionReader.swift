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
        let pb = NSPasteboard.general
        let saved = PasteboardContents(pb)
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

/// A copy of everything on the clipboard, to put it back after reading the selection with ⌘C.
@MainActor
private struct PasteboardContents {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pb: NSPasteboard) {
        items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }
}
