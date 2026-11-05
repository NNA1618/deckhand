import SwiftUI
import AppKit

/// Sizes of a notice in the closed notch. It drops down below the cutout, like the Dynamic Island,
/// instead of spreading sideways over app menus and menu-bar items.
@MainActor
enum ToastLayout {
    /// Height of the row below the cutout.
    static let drop: CGFloat = 30
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let padding: CGFloat = 18
    private static let icon: CGFloat = 16
    private static let spacing: CGFloat = 7

    /// Measured from the text, at least a little wider than the cutout and at most `maxWidth`;
    /// longer text is truncated (in the middle for project names).
    static func width(_ toast: Toast, notchWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let text = ceil((toast.text as NSString).size(withAttributes: [.font: font]).width)
        let content = icon + spacing + text + padding * 2
        return min(maxWidth, max(notchWidth + 16, content)).rounded()
    }
}

/// The closed notch, in the badge window: the black shape behind the cutout, one badge, or a notice.
///
/// It never takes clicks (except the click-to-open zone, handled by the controller), so menu-bar items
/// under the badge ears stay clickable.
struct NotchClosedView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var closed: ClosedNotchModel
    @ObservedObject private var notchSettings = NotchSettings.shared

    private var toast: Toast? { vm.isOpen ? nil : vm.toast }
    private var badge: BadgeKind? { vm.isOpen || vm.toast != nil ? nil : closed.badge }

    private var size: CGSize {
        let n = vm.notchSize
        if let toast {
            return CGSize(width: ToastLayout.width(toast, notchWidth: n.width, maxWidth: vm.toastMaxWidth),
                          height: n.height + ToastLayout.drop)
        }
        if badge != nil { return CGSize(width: n.width + closed.earWidth * 2, height: n.height) }
        return CGSize(width: max(n.width - 6, 10), height: max(n.height - 2, 10))
    }

    /// Without a camera housing the idle notch is drawn, unless the user wants it invisible until hovered.
    private var visible: Bool {
        if vm.isOpen { return false }
        if toast != nil || badge != nil || vm.hasNotch { return true }
        return notchSettings.noNotchStyle == .blackPill || vm.peek
    }

    private struct Key: Equatable {
        var toast: UUID?, badge: BadgeKind?, ear: CGFloat, visible: Bool, open: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: toast != nil || badge != nil ? 8 : 0,
                           bottomRadius: toast != nil ? 18 : (badge != nil ? 14 : 9))
                    .fill(Color.black)

                if let badge {
                    BadgeView(kind: badge, notchWidth: vm.notchSize.width, height: vm.notchSize.height, ear: closed.earWidth)
                        .transition(.opacity)
                }

                if let toast {
                    VStack(spacing: 0) {
                        Spacer().frame(height: vm.notchSize.height)
                        ToastLabel(toast: toast)
                            .padding(.horizontal, 18)
                            .frame(height: ToastLayout.drop - 4)
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .opacity(visible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(NotchController.morph,
                   value: Key(toast: toast?.id, badge: badge, ear: closed.earWidth, visible: visible, open: vm.isOpen))
    }
}

/// The badge chosen by `ClosedNotchModel`.
private struct BadgeView: View {
    let kind: BadgeKind
    let notchWidth: CGFloat
    let height: CGFloat
    let ear: CGFloat

    var body: some View {
        switch kind {
        case .claude: ClaudeBadge(notchWidth: notchWidth, height: height)
        case .timer: TimerBadge(notchWidth: notchWidth, height: height, ear: ear)
        case .music: MusicBadgeHost(notchWidth: notchWidth, height: height)
        case .keepAwake: KeepAwakeBadge(notchWidth: notchWidth, height: height, ear: ear)
        }
    }
}

/// Observes the player only while its badge shows, so track updates don't re-render the rest of the notch.
private struct MusicBadgeHost: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ObservedObject private var player = NowPlayingMonitor.shared

    var body: some View {
        NowPlayingBadge(now: player.now, notchWidth: notchWidth, height: height)
    }
}

/// Icon and text of a notice. "Needs you · my-project" keeps its first part and shortens the project name
/// in the middle, where names differ least.
struct ToastLabel: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(toast.style == .alert ? Theme.warn : Theme.fg)
                .frame(width: 16)
            text
                .font(Font(ToastLayout.font))
                .foregroundColor(Theme.fg)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var text: some View {
        if let range = toast.text.range(of: " · ") {
            HStack(spacing: 0) {
                Text(verbatim: String(toast.text[..<range.upperBound])).fixedSize()
                Text(verbatim: String(toast.text[range.upperBound...])).truncationMode(.middle)
            }
        } else {
            Text(verbatim: toast.text).truncationMode(.tail)
        }
    }
}

/// The open panel, in the panel window. It grows out of the notch into Liquid Glass with a dark tint.
/// The top of the panel runs past the screen edge, so top corners are square and bottom corners round.
struct NotchPanelView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var notchSettings = NotchSettings.shared

    private let panelRadius: CGFloat = 26

    private var size: CGSize {
        if vm.isOpen { return settings.panelSize.size }
        return CGSize(width: max(vm.notchSize.width - 6, 10), height: max(vm.notchSize.height - 2, 10))
    }

    /// While closed this window only shows the shape the panel grows from; on a display without a notch
    /// set to invisible, that shape is invisible too.
    private var closedShapeVisible: Bool { vm.hasNotch || notchSettings.noNotchStyle == .blackPill }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: 0, bottomRadius: vm.isOpen ? panelRadius : 9)
                    .fill(Color.black)
                    .opacity(vm.isOpen ? 0 : (closedShapeVisible ? 1 : 0))

                if vm.isOpen {
                    PanelContent()
                        .id(settings.panelStyle == .solid)   // glass chips are chosen when views are built
                        .padding(.horizontal, 20)
                        .padding(.top, vm.notchSize.height + 8)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }

                if vm.isOpen, let toast = vm.toast {
                    banner(toast)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            // Glass is taller than the panel by its radius so the top rounding falls off screen.
            // It sits in a background so its extra height never affects the content layout.
            .background(alignment: .top) {
                GlassBackground(cornerRadius: panelRadius, style: settings.panelStyle, tint: settings.glassTint)
                    // Solid and glass are different views; snapshots swap glass for a flat fill after launch
                    .id(settings.panelStyle == .solid || Theme.flatForSnapshot)
                    .frame(width: size.width, height: size.height + panelRadius)
                    .offset(y: -panelRadius)
                    .opacity(vm.isOpen ? 1 : 0)
            }
            .clipped(antialiased: true)
            .shadow(color: .black.opacity(vm.isOpen ? 0.45 : 0), radius: 22, y: 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(NotchController.morph, value: vm.isOpen)
        .animation(NotchController.morph, value: vm.toast?.id)
    }

    /// A notice that arrives while the panel is open shows in the band right of the cutout.
    private func banner(_ toast: Toast) -> some View {
        let side = (size.width - vm.notchSize.width) / 2
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            ToastLabel(toast: toast)
                .frame(maxWidth: max(side - 32, 40), alignment: .leading)
                .padding(.leading, 16)
                .frame(width: side, alignment: .leading)
        }
        .frame(width: size.width, height: vm.notchSize.height)
    }
}
