import Foundation
import CoreGraphics
import Combine

/// What opens the panel besides the shortcut.
enum PanelActivation: String, CaseIterable, Identifiable {
    case hover, click, hoverAndClick, shortcut
    var id: String { rawValue }
    var opensOnHover: Bool { self == .hover || self == .hoverAndClick }
    var opensOnClick: Bool { self == .click || self == .hoverAndClick }
}

/// How far the hover trigger reaches past the sides of the physical cutout.
enum HoverArea: String, CaseIterable, Identifiable {
    case narrow, standard, wide
    var id: String { rawValue }
    /// Points added on each side of the cutout. The zone never grows downward out of the menu bar.
    var margin: CGFloat {
        switch self {
        case .narrow: return 0
        case .standard: return 6
        case .wide: return 20
        }
    }
}

/// Which display carries the notch panel.
enum NotchDisplay: String, CaseIterable, Identifiable {
    /// The built-in display with the notch; the main display when there is none (lid closed).
    case builtIn
    /// The display with the menu bar.
    case main
    /// Whichever display the pointer is on; follows it while the panel is closed.
    case pointer
    var id: String { rawValue }
}

/// What a display without a camera housing shows while nothing else is in the notch.
enum NoNotchStyle: String, CaseIterable, Identifiable {
    case blackPill, invisible
    var id: String { rawValue }
}

/// Activation, closing and display settings of the notch. Owned by the notch workstream.
/// Shared notice and badge switches stay in `Settings`.
@MainActor
final class NotchSettings: ObservableObject {
    static let shared = NotchSettings()
    private let d = UserDefaults.standard

    static let hoverDelays: [Double] = [0.1, 0.2, 0.35, 0.5, 1]
    static let closeDelays: [Double] = [0.25, 0.5, 1, 2]

    @Published var activation: PanelActivation { didSet { d.set(activation.rawValue, forKey: "panelActivation") } }
    /// Seconds the pointer must rest on the notch before the panel opens.
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverOpenDelay") } }
    @Published var hoverArea: HoverArea { didSet { d.set(hoverArea.rawValue, forKey: "hoverArea") } }
    /// Off by default: badges sit over menu-bar items, so pointing at them must not open anything.
    @Published var badgeHoverOpens: Bool { didSet { d.set(badgeHoverOpens, forKey: "badgeHoverOpens") } }
    @Published var closeOnPointerExit: Bool { didSet { d.set(closeOnPointerExit, forKey: "closeOnPointerExit") } }
    /// Seconds the pointer must stay away before the panel closes.
    @Published var closeDelay: Double { didSet { d.set(closeDelay, forKey: "closeDelay") } }
    @Published var hapticOnOpen: Bool { didSet { d.set(hapticOnOpen, forKey: "hapticOnOpen") } }
    @Published var dragOpensShelf: Bool { didSet { d.set(dragOpensShelf, forKey: "dragOpensShelf") } }
    @Published var display: NotchDisplay { didSet { d.set(display.rawValue, forKey: "notchDisplay") } }
    @Published var noNotchStyle: NoNotchStyle { didSet { d.set(noNotchStyle.rawValue, forKey: "noNotchStyle") } }

    private init() {
        d.register(defaults: [
            "hoverOpenDelay": 0.2,
            "hoverArea": HoverArea.standard.rawValue,
            "badgeHoverOpens": false,
            "closeOnPointerExit": true,
            "closeDelay": 0.5,
            "hapticOnOpen": true,
            "dragOpensShelf": true,
            "notchDisplay": NotchDisplay.builtIn.rawValue,
            "noNotchStyle": NoNotchStyle.blackPill.rawValue,
        ])
        // 0.4 had a single "open on hover" switch and a 0.08 s default delay that opened on every pass
        let stored = d.string(forKey: "panelActivation").flatMap(PanelActivation.init(rawValue:))
        activation = stored ?? (d.object(forKey: "openOnHover") as? Bool == false ? .shortcut : .hover)
        // Only a stored value counts here: the registered default would always hide the 0.4 one
        let saved = d.persistentDomain(forName: AppPaths.bundleId) ?? [:]
        hoverDelay = saved["hoverOpenDelay"] != nil
            ? d.double(forKey: "hoverOpenDelay")
            : (d.double(forKey: "hoverDelay") >= 0.5 ? 0.5 : 0.2)
        hoverArea = HoverArea(rawValue: d.string(forKey: "hoverArea") ?? "") ?? .standard
        badgeHoverOpens = d.bool(forKey: "badgeHoverOpens")
        closeOnPointerExit = d.bool(forKey: "closeOnPointerExit")
        closeDelay = d.double(forKey: "closeDelay")
        hapticOnOpen = d.bool(forKey: "hapticOnOpen")
        dragOpensShelf = d.bool(forKey: "dragOpensShelf")
        display = NotchDisplay(rawValue: d.string(forKey: "notchDisplay") ?? "") ?? .builtIn
        noNotchStyle = NoNotchStyle(rawValue: d.string(forKey: "noNotchStyle") ?? "") ?? .blackPill
    }

    /// Settings → Notch & Panel → Restore Defaults: activation, closing, look and displays.
    func restoreDefaults() {
        activation = .hover
        hoverDelay = 0.2
        hoverArea = .standard
        badgeHoverOpens = false
        closeOnPointerExit = true
        closeDelay = 0.5
        hapticOnOpen = true
        dragOpensShelf = true
        display = .builtIn
        noNotchStyle = .blackPill
        let s = Settings.shared
        s.hideInFullScreen = true
        s.panelStyle = .tinted
        s.glassTint = 0.38
        s.panelSize = .standard
    }
}
