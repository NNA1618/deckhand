import AppKit
import Combine

/// A kitchen timer in the notch: start, pause, add a minute, and a chime with a notice at the end.
@MainActor
final class Countdown: ObservableObject {
    static let shared = Countdown()

    /// Lengths offered on the Home card, in minutes.
    static let presets = [5, 15, 25, 45]

    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var endsAt: Date?
    /// Time left while paused.
    @Published private(set) var pausedLeft: TimeInterval = 0
    /// The length picked, to mark it on the card.
    @Published private(set) var minutes: Int?

    var onFinish: () -> Void = {}
    private var tick: Task<Void, Never>?

    private init() {}

    var isActive: Bool { isRunning || isPaused }

    func start(minutes: Int) {
        self.minutes = minutes
        run(for: TimeInterval(minutes * 60))
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
        if isPaused { pausedLeft += 60 } else if let endsAt { run(for: endsAt.timeIntervalSinceNow + 60) }
    }

    func stop() {
        tick?.cancel()
        isRunning = false
        isPaused = false
        endsAt = nil
        minutes = nil
    }

    private func run(for seconds: TimeInterval) {
        tick?.cancel()
        endsAt = Date().addingTimeInterval(seconds)
        isRunning = true
        isPaused = false
        tick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.stop()
            NSSound(named: "Glass")?.play()
            self.onFinish()
        }
    }

    /// "12:05" left.
    func remainingText(now: Date = Date()) -> String {
        let left = isPaused ? pausedLeft : max(0, endsAt?.timeIntervalSince(now) ?? 0)
        let s = Int(left.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
