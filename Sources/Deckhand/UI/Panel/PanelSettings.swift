import Foundation
import Combine

/// Tab order and the tab the panel opens on. Which tabs are hidden stays in `Settings.hiddenTabs`.
@MainActor
final class PanelSettings: ObservableObject {
    static let shared = PanelSettings()
    private let d = UserDefaults.standard

    /// Tab raw values in the user's order. Home is always first and isn't stored.
    @Published var tabOrder: [String] { didSet { d.set(tabOrder, forKey: "tabOrder") } }
    /// "last", or a tab raw value such as "home".
    @Published var openTab: String { didSet { d.set(openTab, forKey: "openTab") } }
    /// The tab that was showing when the panel last closed, kept across launches.
    @Published var lastTab: String { didSet { d.set(lastTab, forKey: "lastTab") } }

    nonisolated static let lastUsed = "last"

    private init() {
        d.register(defaults: [
            "tabOrder": NotchTab.allCases.filter { $0 != .home }.map(\.rawValue),
            "openTab": Self.lastUsed,
            "lastTab": NotchTab.home.rawValue,
        ])
        tabOrder = d.stringArray(forKey: "tabOrder") ?? []
        openTab = d.string(forKey: "openTab") ?? Self.lastUsed
        lastTab = d.string(forKey: "lastTab") ?? NotchTab.home.rawValue
    }

    /// Visible tabs in the user's order.
    var visibleTabs: [NotchTab] { Self.ordered(order: tabOrder, hidden: Settings.shared.hiddenTabs) }

    /// All tabs in the user's order, hidden ones included, for Settings.
    var allTabs: [NotchTab] { Self.ordered(order: tabOrder, hidden: []) }

    /// Moves tabs in the Settings list. Offsets count tabs after Home, which can't move.
    func move(from source: IndexSet, to destination: Int) {
        var tabs = allTabs.filter { $0 != .home }
        tabs.move(fromOffsets: source, toOffset: destination)
        tabOrder = tabs.map(\.rawValue)
    }

    /// The tab to show when the panel opens by hover, click or the toggle shortcut.
    var tabWhenOpened: NotchTab {
        Self.tabWhenOpened(choice: openTab, last: lastTab, visible: visibleTabs)
    }

    // MARK: - Pure rules, checked by the self-test

    /// Home first, then the stored order; tabs missing from it (new in an update) keep their default place at the end;
    /// unknown names are dropped; hidden tabs are left out.
    nonisolated static func ordered(order: [String], hidden: [String]) -> [NotchTab] {
        var seen: Set<NotchTab> = [.home]
        var out: [NotchTab] = [.home]
        for name in order {
            guard let tab = NotchTab(rawValue: name), !seen.contains(tab) else { continue }
            seen.insert(tab)
            out.append(tab)
        }
        out += NotchTab.allCases.filter { !seen.contains($0) }
        return out.filter { $0 == .home || !hidden.contains($0.rawValue) }
    }

    /// The tabs in the strip: the visible ones, plus the current tab when a shortcut opened a hidden one,
    /// at its place in the order so it can be seen as selected.
    nonisolated static func strip(order: [String], hidden: [String], current: NotchTab) -> [NotchTab] {
        let visible = ordered(order: order, hidden: hidden)
        guard !visible.contains(current) else { return visible }
        return ordered(order: order, hidden: hidden.filter { $0 != current.rawValue })
    }

    nonisolated static func tabWhenOpened(choice: String, last: String, visible: [NotchTab]) -> NotchTab {
        let wanted = NotchTab(rawValue: choice == lastUsed ? last : choice) ?? .home
        return visible.contains(wanted) ? wanted : .home
    }

    /// The next tab for ⌃Tab (step 1) and ⌃⇧Tab (step -1), wrapping around.
    nonisolated static func neighbor(of current: NotchTab, in tabs: [NotchTab], step: Int) -> NotchTab {
        guard !tabs.isEmpty else { return current }
        guard let i = tabs.firstIndex(of: current) else { return tabs[0] }
        return tabs[(i + step % tabs.count + tabs.count) % tabs.count]
    }
}
