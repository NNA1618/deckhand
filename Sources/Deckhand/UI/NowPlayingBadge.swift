import SwiftUI

/// Shown at the closed notch while music plays: the scrolling title on the left,
/// a small equalizer on the right. The middle stays behind the physical cutout.
/// Both ears are narrow so they never cover app menus or status items next to the notch.
struct NowPlayingBadge: View {
    let now: NowPlaying
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 54

    var body: some View {
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                MarqueeText(text: now.badgeText, isMoving: now.isPlaying)
                    .frame(width: Self.sideWidth - 16, height: height)
                    .padding(.leading, 13)
            }
            .overlay(alignment: .trailing) {
                Equalizer(isPlaying: now.isPlaying)
                    .frame(width: 16, height: 12)
                    .padding(.trailing, 19)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(now.isPlaying ? Text("Playing: \(now.badgeText)") : Text("Paused: \(now.badgeText)"))
    }
}

/// Single-line text that scrolls when it does not fit. Each loop starts with a pause on the
/// beginning of the text, and the first loop starts when the text changes, not at a random point.
struct MarqueeText: View {
    let text: String
    var isMoving = true
    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    private let gap: CGFloat = 28
    private let speed: CGFloat = 24        // points per second
    private let pause: TimeInterval = 1.5  // at the start of each loop

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            ZStack(alignment: .leading) {
                if overflow {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isMoving)) { context in
                        let x = isMoving ? offset(at: context.date) : 0
                        HStack(spacing: gap) { label; label }
                            .offset(x: x)
                            .frame(width: geo.size.width, alignment: .leading)
                            .mask(fade(leading: x < 0))
                    }
                } else {
                    label
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .background(
            label.hidden().background(GeometryReader { g in
                Color.clear
                    .onAppear { textWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in textWidth = w }
            })
        )
        .onChange(of: text) { start = Date() }
        .onChange(of: isMoving) { _, moving in if moving { start = Date() } }
    }

    /// Rests for `pause`, then moves one text width plus the gap, where the second copy lines up
    /// exactly with the first, so the loop has no jump.
    private func offset(at date: Date) -> CGFloat {
        let travel = Double((textWidth + gap) / speed)
        let t = max(date.timeIntervalSince(start), 0).truncatingRemainder(dividingBy: pause + travel)
        return t < pause ? 0 : -CGFloat(t - pause) * speed
    }

    /// The trailing edge always fades into the cutout; the leading edge only while the text moves,
    /// so the first letter is fully visible during the pause.
    private func fade(leading: Bool) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: leading ? .clear : .black, location: 0), .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.fg)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Three bars that bounce while playing and rest when paused. Redraws at most 30 times a second.
struct Equalizer: View {
    var isPlaying = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<3) { i in
                    let rest = [0.35, 0.55, 0.4][i]
                    let h = isPlaying ? 0.3 + 0.7 * abs(sin(t * (4.6 + Double(i) * 1.9) + Double(i))) : rest
                    Capsule()
                        .fill(Theme.fg.opacity(isPlaying ? 1 : 0.6))
                        .frame(width: 3, height: 12 * h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
