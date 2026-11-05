import AppKit
import Combine

/// A kitchen timer in the notch: start, pause, add a minute, and a sound with a notice at the end.
/// With "Alert until I dismiss it" the finished timer keeps ringing (`isRinging`) until dismissed.
@MainActor
final class Countdown: ObservableObject {
    static let shared = Countdown()

    /// The longest timer, in minutes.
    nonisolated static let maxMinutes = 600
    /// How often an alert that waits for dismissal repeats its sound, and for how long.
    nonisolated static let ringInterval: TimeInterval = 5
    nonisolated static let ringFor: TimeInterval = 120

    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    /// Finished and waiting to be dismissed.
    @Published private(set) var isRinging = false
    @Published private(set) var endsAt: Date?
    /// Time left while paused.
    @Published private(set) var pausedLeft: TimeInterval = 0
    /// The length picked, to mark it on the card.
    @Published private(set) var minutes: Int?

    /// Called when the time is up, for the notice in the notch.
    var onFinish: () -> Void = {}
    private var tick: Task<Void, Never>?
    private var ring: Task<Void, Never>?

    private init() {}

    /// Running, paused or ringing: the badge and the Home card show the timer.
    var isActive: Bool { isRunning || isPaused || isRinging }

    func start(minutes: Int) {
        let m = min(max(minutes, 1), Self.maxMinutes)
        stopRinging()
        self.minutes = m
        run(for: TimeInterval(m * 60))
    }

    func pause() {
        guard isRunning, let endsAt else { return }
        tick?.cancel()
        pausedLeft = max(0, endsAt.timeIntervalSinceNow)
        self.endsAt = nil
        isRunning = false
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        run(for: pausedLeft)
    }

    func addMinute() {
        if isPaused {
            pausedLeft = Self.adding(60, to: pausedLeft)
        } else if let endsAt {
            run(for: Self.adding(60, to: endsAt.timeIntervalSinceNow))
        }
    }

    func stop() {
        tick?.cancel()
        stopRinging()
        isRunning = false
        isPaused = false
        endsAt = nil
        minutes = nil
    }

    /// Silences a finished timer.
    func dismiss() { stop() }

    private func run(for seconds: TimeInterval) {
        tick?.cancel()
        endsAt = Date().addingTimeInterval(seconds)
        isRunning = true
        isPaused = false
        tick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.finish()
        }
    }

    private func finish() {
        tick?.cancel()
        isRunning = false
        isPaused = false
        endsAt = nil
        let sound = Settings.shared.soundTimer
        Self.play(sound)
        if UtilitySettings.shared.timerAlertUntilDismissed {
            isRinging = true
            ring = Task { [weak self] in
                var elapsed: TimeInterval = 0
                while elapsed < Self.ringFor {
                    try? await Task.sleep(for: .seconds(Self.ringInterval))
                    guard !Task.isCancelled, self?.isRinging == true else { return }
                    elapsed += Self.ringInterval
                    Self.play(sound)
                }
            }
        } else {
            minutes = nil
        }
        onFinish()
    }

    private func stopRinging() {
        ring?.cancel()
        ring = nil
        isRinging = false
    }

    private static func play(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// "12:05" left; "0:00" while ringing.
    func remainingText(now: Date = Date()) -> String {
        Self.format(seconds: Self.remaining(endsAt: endsAt, pausedLeft: isPaused ? pausedLeft : nil, now: now))
    }

    // MARK: - Pure math, checked by the self-test

    nonisolated static func remaining(endsAt: Date?, pausedLeft: TimeInterval?, now: Date) -> TimeInterval {
        if let pausedLeft { return max(0, pausedLeft) }
        return max(0, endsAt?.timeIntervalSince(now) ?? 0)
    }

    /// Whole seconds rounded up, so a fresh 5-minute timer reads "5:00", not "4:59".
    nonisolated static func format(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Adds time without going past the longest timer.
    nonisolated static func adding(_ seconds: TimeInterval, to left: TimeInterval) -> TimeInterval {
        min(max(0, left) + seconds, TimeInterval(maxMinutes * 60))
    }
}
