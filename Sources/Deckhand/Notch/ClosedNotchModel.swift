import Foundation
import Combine

/// The one badge the closed notch shows, and how wide its ears are.
///
/// The closed notch used to observe six shared objects directly and re-render on every Claude Code event.
/// This model listens to them and publishes only when the visible badge or its size actually changes.
@MainActor
final class ClosedNotchModel: ObservableObject {
    @Published private(set) var badge: BadgeKind?
    /// Width of each ear beside the cutout for the current badge.
    @Published private(set) var earWidth: CGFloat = 0

    /// Set by the controller from the cached full-screen state of the notch display.
    @Published var fullScreen = false { didSet { if fullScreen != oldValue { scheduleUpdate() } } }

    private var subscriptions = Set<AnyCancellable>()
    private var pending = false
    private var tick: Timer?

    init() {
        let sources: [AnyPublisher<Void, Never>] = [
            ClaudeCodeMonitor.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Countdown.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            NowPlayingMonitor.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            KeepAwake.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            Settings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(sources)
            .sink { [weak self] in self?.scheduleUpdate() }
            .store(in: &subscriptions)
        update()
    }

    /// objectWillChange fires before the new value is stored, so read on the next turn, once per burst.
    private func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.update()
        }
    }

    private func update() {
        let s = Settings.shared
        let inputs = BadgeKind.Inputs(
            claudeActive: !ClaudeCodeMonitor.shared.active.isEmpty, claudeEnabled: s.claudeInNotch,
            timerActive: Countdown.shared.isActive, timerRinging: Countdown.shared.isRinging, timerEnabled: s.badgeTimer,
            musicPlaying: NowPlayingMonitor.shared.showsInNotch, musicEnabled: s.showPlayingInNotch,
            keepAwakeActive: KeepAwake.shared.isActive, keepAwakeEnabled: s.keepAwakeIndicator,
            fullScreen: fullScreen, hideInFullScreen: s.hideBadgesInFullScreen
        )
        let kind = BadgeKind.pick(inputs)
        let width = Self.earWidth(for: kind)
        if kind != badge { badge = kind }
        if width != earWidth { earWidth = width }

        // Time badges change width when they cross an hour; check now and then while one shows
        let needsTick = kind == .timer || kind == .keepAwake
        if needsTick, tick == nil {
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else if !needsTick {
            tick?.invalidate()
            tick = nil
        }
    }

    private static func earWidth(for kind: BadgeKind?) -> CGFloat {
        switch kind {
        case nil: return 0
        case .claude: return ClaudeBadge.sideWidth
        case .music: return NowPlayingBadge.sideWidth
        case .timer:
            if BadgeText.timerRinging() { return BadgeText.ear(for: BadgeText.timeIsUp, cap: 100) }
            return BadgeText.ear(for: BadgeText.timerTemplate(left: BadgeText.timerLeft()))
        case .keepAwake: return BadgeText.ear(for: BadgeText.keepAwakeTemplate(left: KeepAwake.shared.endsAt?.timeIntervalSinceNow))
        }
    }
}
