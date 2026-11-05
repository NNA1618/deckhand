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
///
/// It sits in the always-visible closed-notch badge, so the turning is a Core Animation layer: the window
/// server spins it and the app redraws nothing. It stands still with Reduce Motion on, and in snapshot
/// runs, which can't capture a running layer animation.
private struct WorkingRing: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One turn takes this long.
    static let period: TimeInterval = 1.4
    /// The arc's share of the circle.
    static let arc: CGFloat = 0.28

    var body: some View {
        Group {
            if reduceMotion || AppPaths.isSnapshot {
                Circle()
                    .trim(from: 0, to: Self.arc)
                    .stroke(Theme.fg, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                SpinningArc(lineWidth: lineWidth, color: NSColor(Theme.fg))
            }
        }
        .frame(width: size * 1.32, height: size * 1.32)
        .allowsHitTesting(false)
    }

    private var lineWidth: CGFloat { max(1.5, size * 0.1) }
}

/// The turning arc as a shape layer with a repeating rotation, run by Core Animation outside the app.
private struct SpinningArc: NSViewRepresentable {
    let lineWidth: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> ArcView { ArcView() }

    func updateNSView(_ view: ArcView, context: Context) {
        view.arc.lineWidth = lineWidth
        view.arc.strokeColor = color.cgColor
        view.needsLayout = true
    }

    final class ArcView: NSView {
        let arc = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineCap = .round
            arc.strokeEnd = WorkingRing.arc
            layer?.addSublayer(arc)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi   // clockwise
            spin.duration = WorkingRing.period
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            arc.add(spin, forKey: "spin")
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let inset = arc.lineWidth / 2
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
