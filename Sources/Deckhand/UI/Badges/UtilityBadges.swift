import SwiftUI

/// Around the closed notch while the timer runs: a timer icon and the time left.
struct TimerBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 54
    @ObservedObject private var timer = Countdown.shared

    var body: some View {
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.fg)
                    .padding(.leading, 18)
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(timer.remainingText(now: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
                .padding(.trailing, 14)
            }
    }
}


/// Shown around the closed notch while Keep Awake is on: a cup on the left, time left on the right.
struct KeepAwakeBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 46
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.fg)
                    .padding(.leading, 18)
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text(awake.remainingText(now: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
                .padding(.trailing, 14)
            }
    }
}
