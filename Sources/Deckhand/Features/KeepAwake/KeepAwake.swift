import Foundation
import IOKit.pwr_mgt
import Combine

/// Keeps the Mac from going to sleep, like `caffeinate` or Amphetamine.
///
/// Holds power assertions that stop idle sleep (and optionally display sleep).
/// They are released when the session ends or Deckhand quits, so nothing outlives the app.
/// A closed lid still puts the Mac to sleep unless an external display is connected.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    /// Choices offered in the panel and the menu. `nil` means until turned off.
    static let durations: [TimeInterval?] = [3600, 2 * 3600, 4 * 3600, nil]

    /// Why a session ended without the user turning it off.
    enum EndReason: Equatable {
        case timeUp
        case lowBattery(percent: Int)
    }

    @Published private(set) var isActive = false
    /// When the session ends; `nil` while active means until turned off.
    @Published private(set) var endsAt: Date?
    /// The length picked for the current session, to mark it in the UI.
    @Published private(set) var duration: TimeInterval?

    /// Called when a session ends by itself, for the notice in the notch.
    var onEnd: (EndReason) -> Void = { _ in }

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var endTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private static let reason = "Deckhand Keep Awake" as CFString

    private init() {
        // "Let the display turn off" applies to a running session at once.
        // @Published fires before the value is stored, so the new value is passed along.
        Settings.shared.$keepAwakeAllowDisplaySleep.dropFirst().sink { [weak self] allow in
            self?.updateDisplayAssertion(allowDisplaySleep: allow)
        }.store(in: &subscriptions)
    }

    /// Starts a session or replaces the current one.
    func start(for duration: TimeInterval?) {
        release()
        guard Self.create(kIOPMAssertionTypePreventUserIdleSystemSleep, &systemAssertion) else {
            Log.info("keep awake: assertion failed")
            release()
            return
        }
        updateDisplayAssertion(allowDisplaySleep: Settings.shared.keepAwakeAllowDisplaySleep)
        isActive = true
        self.duration = duration
        endsAt = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled, let self else { return }
                self.stop()
                self.onEnd(.timeUp)
            }
        }
        Log.info("keep awake: on for \(duration.map { "\(Int($0))s" } ?? "ever")")
    }

    func stop() {
        guard isActive else { return }
        release()
        Log.info("keep awake: off")
    }

    /// Off when on; otherwise on for the default duration from Settings.
    func toggle() {
        isActive ? stop() : start(for: Settings.shared.keepAwakeDefaultDuration)
    }

    /// Turns the session off when the battery drops below the floor from Settings.
    func batteryChanged(from old: BatteryMonitor.State?, to new: BatteryMonitor.State) {
        guard isActive,
              Self.shouldStop(previous: old, now: new, floor: UtilitySettings.shared.keepAwakeBatteryFloor) else { return }
        stop()
        onEnd(.lowBattery(percent: new.percent))
    }

    private func updateDisplayAssertion(allowDisplaySleep: Bool) {
        guard systemAssertion != 0 else { return }
        if allowDisplaySleep {
            if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        } else if displayAssertion == 0 {
            if !Self.create(kIOPMAssertionTypePreventUserIdleDisplaySleep, &displayAssertion) {
                Log.info("keep awake: display assertion failed")
            }
        }
    }

    private static func create(_ type: String, _ id: inout IOPMAssertionID) -> Bool {
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess
    }

    private func release() {
        endTask?.cancel()
        endTask = nil
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        isActive = false
        endsAt = nil
        duration = nil
    }

    /// For the self-test: whether the system-sleep and display-sleep assertions are held.
    var holdsAssertion: Bool { systemAssertion != 0 }
    var holdsDisplayAssertion: Bool { displayAssertion != 0 }

    // MARK: - Rules, checked by the self-test

    /// Stop when running on battery below the floor, but only on the way down: when the level just crossed it
    /// or the charger was just unplugged. A session started on purpose below the floor keeps running.
    nonisolated static func shouldStop(previous: BatteryMonitor.State?, now: BatteryMonitor.State, floor: Int) -> Bool {
        guard floor > 0, !now.onAC, now.percent < floor else { return false }
        guard let previous else { return false }
        return previous.onAC || previous.percent >= floor
    }

    // MARK: - Labels

    static func title(for duration: TimeInterval?) -> String {
        guard let duration else { return String(localized: "Until turned off") }
        return format(duration, style: .full)
    }

    static func shortTitle(for duration: TimeInterval?) -> String {
        guard let duration else { return "∞" }
        return format(duration, style: .abbreviated)
    }

    /// "1h 42m" / "1 ч 42 мин" left, never "0m".
    func remainingDescription(now: Date = Date()) -> String {
        guard let endsAt else { return "∞" }
        let left = max(60, endsAt.timeIntervalSince(now))
        // Round up to the minute, so a fresh 1-hour session reads "1h", not "59m"
        return Self.format((left / 60).rounded(.up) * 60, style: .abbreviated)
    }

    /// "1:42" left, or "∞". Kept for the closed-notch badge.
    func remainingText(now: Date = Date()) -> String {
        guard let endsAt else { return "∞" }
        let left = max(0, Int(endsAt.timeIntervalSince(now)))
        let h = left / 3600, m = (left % 3600) / 60
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "0:%02d", max(m, 1))
    }

    private static func format(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = style
        return f.string(from: seconds) ?? ""
    }
}
