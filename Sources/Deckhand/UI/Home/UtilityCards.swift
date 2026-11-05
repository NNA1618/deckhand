import SwiftUI

// MARK: - Timer

struct TimerCard: View {
    @ObservedObject private var timer = Countdown.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(timer.isActive ? Theme.fg : Theme.fgDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Timer").font(Theme.label).foregroundColor(Theme.fg)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timer.isActive ? timer.remainingText(now: context.date) : String(localized: "Off"))
                            .font(timer.isActive ? Theme.caption.monospacedDigit() : Theme.caption)
                            .foregroundColor(Theme.fgMute)
                    }
                }
                Spacer()
                if timer.isActive {
                    roundButton(timer.isPaused ? "play.fill" : "pause.fill", timer.isPaused ? "Resume" : "Pause") {
                        timer.isPaused ? timer.resume() : timer.pause()
                    }
                    roundButton("xmark", "Stop") { timer.stop() }
                }
            }
            HStack(spacing: 6) {
                ForEach(Countdown.presets, id: \.self) { m in
                    Button { timer.start(minutes: m) } label: {
                        Chip(text: KeepAwake.shortTitle(for: TimeInterval(m * 60)), active: timer.isActive && timer.minutes == m)
                    }
                    .buttonStyle(.plain)
                }
                if timer.isActive {
                    Button { timer.addMinute() } label: { Chip(text: "+1") }
                        .buttonStyle(.plain)
                        .help(Text("Add a minute"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func roundButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.fg)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.surface2))
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }
}


// MARK: - Quick toggles

struct QuickTogglesCard: View {
    @ObservedObject private var toggles = QuickToggles.shared
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(QuickToggles.Toggle.allCases) { t in
                    let on = toggles.isOn(t)
                    Button { toggles.flip(t) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t.symbol(on: on))
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 14)
                            Text(t.title).font(Theme.label).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(on ? .black : Theme.fgDim)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent : Theme.surface2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(t.help))
                }
            }
            if let error = toggles.error {
                Text(error).font(Theme.caption).foregroundColor(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { toggles.refresh() }
    }
}


// MARK: - Keep Awake

/// Home tab control: a switch and the session lengths.
struct KeepAwakeCard: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(awake.isActive ? Theme.fg : Theme.fgDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").font(Theme.label).foregroundColor(Theme.fg)
                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        Text(status(now: context.date)).font(Theme.caption).foregroundColor(Theme.fgMute)
                    }
                }
                Spacer()
                Toggle("Keep Awake", isOn: Binding(get: { awake.isActive }, set: { _ in awake.toggle() }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            HStack(spacing: 6) {
                ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, d in
                    let active = awake.isActive && awake.duration == d
                    Button { active ? awake.stop() : awake.start(for: d) } label: {
                        Chip(text: KeepAwake.shortTitle(for: d), active: active)
                    }
                    .buttonStyle(.plain)
                    .help(Text(KeepAwake.title(for: d)))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func status(now: Date) -> String {
        guard awake.isActive else { return String(localized: "Off") }
        if awake.endsAt == nil { return String(localized: "On until turned off") }
        return String(localized: "On, \(awake.remainingText(now: now)) left")
    }
}
