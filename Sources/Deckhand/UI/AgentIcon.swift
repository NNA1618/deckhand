import SwiftUI

/// A coding agent's own icon, with its state as a small mark on top: a turning ring while it
/// works, an orange hand while it waits for you. The icon comes from the installed app
/// (the Claude app for Claude Code); without it a neutral symbol in a rounded square stands in.
/// Reusable anywhere an agent is shown: session rows, the closed-notch badge, tabs, Settings.
struct AgentIcon: View {
    var provider: AgentProvider = .claudeCode
    var size: CGFloat = 16
    var state: ClaudeSession.State?

    var body: some View {
        icon
            .frame(width: size, height: size)
            .overlay { if state == .working { WorkingRing(size: size) } }
            .overlay(alignment: .bottomTrailing) {
                if state == .waiting {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: max(7, size * 0.42), weight: .bold))
                        .foregroundStyle(.white)
                        .padding(max(1.5, size * 0.08))
                        .background(Circle().fill(Theme.warn))
                        .offset(x: size * 0.22, y: size * 0.22)
                }
            }
            .accessibilityLabel(Text(verbatim: provider.name))
    }

    @ViewBuilder private var icon: some View {
        if let image = provider.appIcon {
            Image(nsImage: image).resizable().interpolation(.high)
                .opacity(state == .idle ? 0.55 : 1)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Theme.surface2)
                .overlay {
                    Image(systemName: provider.fallbackSymbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(state == .idle ? Theme.fgMute : Theme.fg)
                }
        }
    }
}

/// A short arc that turns around the icon while the agent works.
private struct WorkingRing: View {
    let size: CGFloat
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Theme.fg, style: StrokeStyle(lineWidth: max(1.5, size * 0.1), lineCap: .round))
            .frame(width: size * 1.32, height: size * 1.32)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .allowsHitTesting(false)
    }
}
