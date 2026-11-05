import SwiftUI

// MARK: - Card template

/// The card every Home section uses: same padding, corner radius and glass.
struct HomeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Icon, title and a one-line status, with optional buttons on the right.
struct CardHeader<Status: View, Trailing: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var active = false
    @ViewBuilder var status: Status
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? Theme.fg : Theme.fgDim)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.label).foregroundColor(Theme.fg).lineLimit(1)
                status
                    .font(Theme.caption)
                    .foregroundColor(Theme.fgMute)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            trailing
        }
        .frame(minHeight: 28)
    }
}

/// A round icon button, 26 pt so it is easy to hit.
struct RoundButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.fg)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.surface2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// A capsule choice on Home, at least 24 pt tall. White when it is the active choice.
struct CardChip<Label: View>: View {
    var active = false
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(Theme.label.monospacedDigit())
                .lineLimit(1)
                .foregroundColor(active ? .black : Theme.fgDim)
                .padding(.horizontal, 9)
                .frame(minWidth: 30, minHeight: 24)
                .background(Capsule().fill(active ? Theme.accent : Theme.surface2))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Timer

struct TimerCard: View {
    @ObservedObject private var timer = Countdown.shared
    @ObservedObject private var settings = UtilitySettings.shared
    /// The custom length being picked, while the stepper row is showing.
    @State private var custom: Int?

    var body: some View {
        HomeCard {
            CardHeader(symbol: timer.isRinging ? "bell.fill" : "timer", title: "Timer", active: timer.isActive) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status(now: context.date))
                }
            } trailing: {
                if timer.isRunning || timer.isPaused {
                    RoundButton(symbol: "xmark", label: "Stop") { timer.stop() }
                }
            }
            controls
        }
    }

    @ViewBuilder private var controls: some View {
        if timer.isRinging {
            CardChip(active: true, action: { timer.dismiss() }) { Text("Dismiss") }
        } else if timer.isActive {
            HStack(spacing: 6) {
                CardChip(action: { timer.isPaused ? timer.resume() : timer.pause() }) {
                    Label(timer.isPaused ? "Resume" : "Pause", systemImage: timer.isPaused ? "play.fill" : "pause.fill")
                }
                CardChip(action: { timer.addMinute() }) { Text("+1 min") }
                    .help(Text("Add a minute"))
            }
        } else if let minutes = custom {
            customRow(minutes)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(settings.timerPresets.enumerated()), id: \.offset) { _, m in
                    CardChip(action: { timer.start(minutes: m) }) { Text(verbatim: "\(m)") }
                        .help(Text(KeepAwake.title(for: TimeInterval(m * 60))))
                        .accessibilityLabel(Text(KeepAwake.title(for: TimeInterval(m * 60))))
                }
                CardChip(action: { custom = settings.timerPresets.last ?? 30 }) {
                    Image(systemName: "ellipsis")
                }
                .help(Text("Other length"))
                .accessibilityLabel(Text("Other length"))
            }
        }
    }

    /// − 30 min + and a start button, for lengths that aren't presets.
    private func customRow(_ minutes: Int) -> some View {
        HStack(spacing: 6) {
            RoundButton(symbol: "minus", label: "Shorter") { custom = Self.step(minutes, by: -1) }
            Text(KeepAwake.shortTitle(for: TimeInterval(minutes * 60)))
                .font(Theme.label.monospacedDigit())
                .foregroundColor(Theme.fg)
                .lineLimit(1)
                .frame(minWidth: 48)
            RoundButton(symbol: "plus", label: "Longer") { custom = Self.step(minutes, by: 1) }
            RoundButton(symbol: "play.fill", label: "Start") {
                timer.start(minutes: minutes)
                custom = nil
            }
            RoundButton(symbol: "xmark", label: "Cancel") { custom = nil }
        }
    }

    /// One minute at a time up to 10, then 5 minutes, then 15 above an hour.
    static func step(_ minutes: Int, by direction: Int) -> Int {
        let size = direction > 0 ? (minutes >= 60 ? 15 : minutes >= 10 ? 5 : 1)
                                 : (minutes > 60 ? 15 : minutes > 10 ? 5 : 1)
        let next = minutes + size * direction
        // Land on the grid after crossing a boundary, e.g. 12 → 10 rather than 7
        let snapped = direction > 0 ? next - next % size : next + (size - next % size) % size
        return min(max(snapped, 1), Countdown.maxMinutes)
    }

    private func status(now: Date) -> String {
        if timer.isRinging { return String(localized: "Time is up") }
        if timer.isPaused { return String(localized: "Paused, \(timer.remainingText(now: now))") }
        if timer.isRunning { return String(localized: "\(timer.remainingText(now: now)) left") }
        return String(localized: "Length in minutes")
    }
}

// MARK: - Quick toggles

struct QuickTogglesCard: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var toggles = QuickToggles.shared
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(QuickToggles.Toggle.allCases) { t in tile(t) }
            }
            // Questions and errors cover the tiles instead of growing the card, so the Home layout never moves
            .overlay {
                if let t = toggles.confirming {
                    confirmation(t)
                } else if let problem = toggles.problem {
                    problemSheet(problem)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { toggles.refresh() }
    }

    private func tile(_ t: QuickToggles.Toggle) -> some View {
        let on = toggles.isOn(t)
        let unavailable = t == .mute && !toggles.canMute
        return Button { toggles.flip(t, beforePrompt: vm.requestClose) } label: {
            HStack(spacing: 6) {
                Group {
                    if toggles.pending.contains(t) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: t.symbol(on: on)).font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(width: 14)
                // Two lines rather than "Скрытые фа…" when a Russian label is wider than the tile
                Text(t.title)
                    .font(Theme.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(on ? .black : Theme.fgDim)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent : Theme.surface2))
            .contentShape(Rectangle())
            .opacity(unavailable ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(unavailable || toggles.pending.contains(t))
        .help(Text(unavailable ? String(localized: "The current sound output has no mute control.") : t.help))
        .accessibilityLabel(Text(t.title))
        .accessibilityValue(Text(on ? "On" : "Off"))
    }

    /// Asks before Finder restarts, on top of the tiles so nothing below moves.
    private func confirmation(_ t: QuickToggles.Toggle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Finder will restart to apply this.")
                .font(Theme.caption)
                .foregroundColor(Theme.fg)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                CardChip(active: true, action: { toggles.confirm() }) { Text("Restart Finder") }
                CardChip(action: { toggles.cancelConfirmation() }) { Text("Cancel") }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.12)))
    }

    /// What went wrong, with the full explanation in the tooltip and a way to fix or dismiss it.
    private func problemSheet(_ problem: QuickToggles.Problem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(problem.message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(Theme.caption)
            .foregroundColor(Theme.warn)
            HStack(spacing: 6) {
                if problem.opensAutomation {
                    CardChip(active: true, action: { toggles.openAutomationSettings() }) { Text("Allow…") }
                }
                CardChip(action: { toggles.dismissProblem() }) { Text("Dismiss") }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.12)))
        .help(Text(problem.detail))
    }
}


// MARK: - Keep Awake

/// Home tab control: pick a length to start, the active one again or × to stop.
struct KeepAwakeCard: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        HomeCard {
            CardHeader(symbol: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", title: "Keep Awake", active: awake.isActive) {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text(status(now: context.date))
                }
            } trailing: {
                if awake.isActive {
                    RoundButton(symbol: "xmark", label: "Turn Off") { awake.stop() }
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, d in
                    let active = awake.isActive && awake.duration == d
                    CardChip(active: active, action: { active ? awake.stop() : awake.start(for: d) }) {
                        Text(KeepAwake.shortTitle(for: d))
                    }
                    .help(Text(KeepAwake.title(for: d)))
                    .accessibilityLabel(Text(KeepAwake.title(for: d)))
                }
            }
        }
    }

    private func status(now: Date) -> String {
        guard awake.isActive else { return String(localized: "Off") }
        if awake.endsAt == nil { return String(localized: "On, no time limit") }
        return String(localized: "\(awake.remainingDescription(now: now)) left")
    }
}
