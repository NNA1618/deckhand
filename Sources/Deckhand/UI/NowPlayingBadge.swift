import SwiftUI

/// Shown around the closed notch while music plays: a scrolling title on the left,
/// a small equalizer on the right. The middle stays behind the physical cutout.
struct NowPlayingBadge: View {
    let now: NowPlaying
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 130

    var body: some View {
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                MarqueeText(text: now.artist.isEmpty ? now.title : "\(now.title) · \(now.artist)")
                    .frame(width: Self.sideWidth - 26, height: height)
                    .padding(.leading, 16)
            }
            .overlay(alignment: .trailing) {
                Equalizer()
                    .frame(width: 22, height: 12)
                    .padding(.trailing, 18)
            }
    }
}

/// Single-line text that scrolls when it does not fit.
struct MarqueeText: View {
    let text: String
    @State private var textWidth: CGFloat = 0

    private let gap: CGFloat = 32
    private let speed: CGFloat = 26   // points per second

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width + 1
            ZStack(alignment: .leading) {
                if overflow {
                    TimelineView(.animation) { context in
                        let cycle = Double((textWidth + gap) / speed)
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                        HStack(spacing: gap) { label; label }
                            .offset(x: -CGFloat(t) * speed)
                    }
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.9), .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
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
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.fg)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Four bars bouncing at different rates.
struct Equalizer: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4) { i in
                    let phase = t * (5.0 + Double(i) * 1.7) + Double(i)
                    let h = 0.35 + 0.65 * abs(sin(phase))
                    Capsule()
                        .fill(Theme.fg)
                        .frame(width: 3, height: 12 * h)
                }
            }
        }
    }
}
