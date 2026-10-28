import SwiftUI
import AppKit

/// Monochrome in the spirit of macOS: dark glass, white as the accent, grey steps.
/// System fonts (SF Pro / SF Mono) so the app feels native.
enum Theme {
    static let bg = Color.black
    static let surface = Color.white.opacity(0.06)
    static let surface2 = Color.white.opacity(0.10)
    static let border = Color.white.opacity(0.10)
    static let fg = Color.white.opacity(0.95)
    static let fgDim = Color.white.opacity(0.66)
    static let fgMute = Color.white.opacity(0.42)
    /// The accent is white: active state, selected tab, primary button.
    static let accent = Color.white
    static let accentSoft = Color.white.opacity(0.16)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.04)

    /// `--snapshot` cannot capture glass, so it swaps glass for flat dark fills.
    nonisolated(unsafe) static var flatForSnapshot = false

    static let title: Font = .system(size: 15, weight: .semibold)
    static let body: Font = .system(size: 13)
    static let caption: Font = .system(size: 11)
    static let label: Font = .system(size: 11, weight: .medium)
    static let mono: Font = .system(size: 12, design: .monospaced)
    static let monoSmall: Font = .system(size: 10, weight: .medium, design: .monospaced)
}

// MARK: - Glass

/// Liquid Glass on macOS 26, a regular blur on older systems.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tint: NSColor = NSColor.black.withAlphaComponent(0.38)

    func makeNSView(context: Context) -> NSView {
        if Theme.flatForSnapshot {
            let flat = NSView()
            flat.wantsLayer = true
            flat.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
            flat.layer?.cornerRadius = cornerRadius
            return flat
        }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.style = .regular
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        return blur
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
        } else {
            view.layer?.cornerRadius = cornerRadius
        }
    }
}

extension View {
    /// Glass backing for controls inside the panel (buttons, tabs, fields).
    @ViewBuilder
    func glassChip<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if Theme.flatForSnapshot {
            self.background(Theme.surface2, in: shape)
        } else if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(Theme.surface2, in: shape)
        }
    }
}

// MARK: - Notch shape

/// Top edge flush with the screen with concave ears, rounded bottom. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.height - t) / 2, (rect.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Shared controls

struct Chip: View {
    let text: String
    var active = false
    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundColor(active ? .black : Theme.fgDim)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(active ? Theme.accent : Theme.surface2))
    }
}

/// Primary button: a white capsule with black text, like Apple's prominent buttons.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.label)
                .foregroundColor(.black)
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(Capsule().fill(Theme.accent))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// Secondary button: a glass capsule.
struct GlassButton: View {
    let title: LocalizedStringKey
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                Text(title).font(Theme.label)
            }
            .foregroundColor(Theme.fg)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .contentShape(Capsule())
            .glassChip(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.fgMute)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.fg)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(Theme.fgMute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .glassChip(in: Capsule())
    }
}

struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil
    var body: some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundColor(Theme.fgMute)
            Text(title).font(Theme.body).foregroundColor(Theme.fgDim)
            if let hint { Text(hint).font(Theme.caption).foregroundColor(Theme.fgMute) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Fades scrolling content out at the bottom edge instead of cutting it hard.
    func fadeBottom(_ height: CGFloat = 28) -> some View {
        mask(
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height)
            }
        )
    }
}
