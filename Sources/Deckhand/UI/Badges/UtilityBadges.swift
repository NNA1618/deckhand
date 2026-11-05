import SwiftUI
import AppKit

/// Text and sizes of the time badges. Pure except for text measurement, for the self-test.
@MainActor
enum BadgeText {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// The app's own language (Settings → General → Language), which `Locale.current` doesn't follow.
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    /// "1h 42m" / "1 ч 42 мин", "42m" / "42 мин", and "∞" until turned off.
    static func keepAwake(left: TimeInterval?, locale: Locale = locale) -> String {
        guard let left else { return "∞" }
        // Round up so "1m" shows until the very end instead of "0m"
        let minutes = max(1, Int((left / 60).rounded(.up)))
        return hoursMinutes(TimeInterval(minutes * 60), locale: locale)
    }

    /// "4:59" under an hour, "1h 02m"-style past it, so the badge never outgrows its ears.
    static func timer(left: TimeInterval, locale: Locale = locale) -> String {
        let s = max(0, Int(left.rounded(.up)))
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return hoursMinutes(TimeInterval(s - s % 60), locale: locale)
    }

    /// The widest text the badge shows until the next hour boundary, so the shape doesn't jitter every second.
    static func timerTemplate(left: TimeInterval) -> String {
        left < 3600 ? (left < 600 ? "8:88" : "88:88") : hoursMinutes(TimeInterval(Int(left) / 3600 * 3600 + 59 * 60), locale: locale)
    }

    static func keepAwakeTemplate(left: TimeInterval?) -> String {
        guard let left else { return "∞" }
        return hoursMinutes(TimeInterval(Int(max(left, 0)) / 3600 * 3600 + 59 * 60), locale: locale)
    }

    static func timerLeft(now: Date = Date()) -> TimeInterval {
        let c = Countdown.shared
        return c.isPaused ? c.pausedLeft : max(0, c.endsAt?.timeIntervalSince(now) ?? 0)
    }

    /// A finished timer waiting to be dismissed: still active, nothing left, not paused.
    static func timerRinging(now: Date = Date()) -> Bool {
        let c = Countdown.shared
        return c.isActive && !c.isPaused && timerLeft(now: now) <= 0
    }

    static var timeIsUp: String { String(localized: "Time is up") }

    /// The notch shape's concave top corners take this much of each ear's outer edge.
    static let earCurve: CGFloat = 8

    static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Ear width for a badge with an icon on one side and `text` on the other: 40–76 pt,
    /// up to 100 pt for the finished timer's words.
    static func ear(for text: String, cap: CGFloat = 76) -> CGFloat {
        min(cap, max(40, width(text) + 22 + earCurve))
    }

    private static func hoursMinutes(_ seconds: TimeInterval, locale: Locale) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        f.calendar = calendar
        return f.string(from: seconds) ?? ""
    }
}

/// Around the closed notch while the timer runs: a timer icon and the time left.
struct TimerBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    let ear: CGFloat
    @ObservedObject private var timer = Countdown.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let ringing = BadgeText.timerRinging(now: context.date)
            Color.clear
                .frame(width: notchWidth + ear * 2, height: height)
                .overlay(alignment: .leading) {
                    Image(systemName: ringing ? "bell.fill" : (timer.isPaused ? "pause.fill" : "timer"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ringing ? Theme.warn : Theme.fg)
                        .frame(width: ear - BadgeText.earCurve, alignment: .center)
                        .padding(.leading, BadgeText.earCurve)
                }
                .overlay(alignment: .trailing) {
                    Text(ringing ? BadgeText.timeIsUp : BadgeText.timer(left: BadgeText.timerLeft(now: context.date)))
                        .font(Font(BadgeText.font))
                        .foregroundColor(ringing ? Theme.warn : Theme.fg)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: ear - BadgeText.earCurve, alignment: .center)
                        .padding(.trailing, BadgeText.earCurve)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Timer"))
    }
}

/// Shown around the closed notch while Keep Awake is on: a cup on the left, time left on the right.
struct KeepAwakeBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    let ear: CGFloat
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Color.clear
            .frame(width: notchWidth + ear * 2, height: height)
            .overlay(alignment: .leading) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.fg)
                    .frame(width: ear - BadgeText.earCurve, alignment: .center)
                    .padding(.leading, BadgeText.earCurve)
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text(BadgeText.keepAwake(left: awake.endsAt?.timeIntervalSince(context.date)))
                        .font(Font(BadgeText.font))
                        .foregroundColor(Theme.fg)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: ear - BadgeText.earCurve, alignment: .center)
                        .padding(.trailing, BadgeText.earCurve)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Keep Awake"))
    }
}
