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

    @Published private(set) var isActive = false
    /// When the session ends; `nil` while active means until turned off.
    @Published private(set) var endsAt: Date?
    /// The length picked for the current session, to mark it in the UI.
    @Published private(set) var duration: TimeInterval?

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var endTask: Task<Void, Never>?

    private init() {}

    /// Starts a session or replaces the current one.
    func start(for duration: TimeInterval?) {
        release()
        let reason = "Deckhand Keep Awake" as CFString
        var ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion) == kIOReturnSuccess
        if ok && !Settings.shared.keepAwakeAllowDisplaySleep {
            ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion) == kIOReturnSuccess
        }
        guard ok else {
            Log.info("keep awake: assertion failed")
            release()
            return
        }
        isActive = true
        self.duration = duration
        endsAt = duration.map { Date().addingTimeInterval($0) }
        if let duration {
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stop()
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

    private func release() {
        endTask?.cancel()
        endTask = nil
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        isActive = false
        endsAt = nil
        duration = nil
    }

    /// For the self-test: whether the system-sleep assertion is held.
    var holdsAssertion: Bool { systemAssertion != 0 }

    // MARK: - Labels

    static func title(for duration: TimeInterval?) -> String {
        guard let duration else { return String(localized: "Until turned off") }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .full
        return f.string(from: duration) ?? ""
    }

    static func shortTitle(for duration: TimeInterval?) -> String {
        guard let duration else { return "∞" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: duration) ?? ""
    }

    /// "1:42" left, or "∞".
    func remainingText(now: Date = Date()) -> String {
        guard let endsAt else { return "∞" }
        let left = max(0, Int(endsAt.timeIntervalSince(now)))
        let h = left / 3600, m = (left % 3600) / 60
        return h > 0 ? String(format: "%d:%02d", h, m) : String(format: "0:%02d", max(m, 1))
    }
}
