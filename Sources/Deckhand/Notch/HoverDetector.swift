import AppKit

/// Polls the cursor 60 times a second and reports entering and leaving a zone.
/// The zone and the cursor share global Cocoa coordinates.
@MainActor
final class HoverDetector {
    private var timer: Timer?
    private var isInside = false
    private var enteredAt: Date?
    private var leftAt: Date?

    private let zone: () -> CGRect
    private let onEnter: () -> Void
    private let onExit: () -> Void

    /// How long the cursor must stay in the zone to open, so passing over the notch does nothing.
    var enterDelay: TimeInterval = 0.08
    /// How long the cursor must stay outside the zone to close.
    var exitDelay: TimeInterval = 0.25

    init(zone: @escaping () -> CGRect, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.zone = zone
        self.onEnter = onEnter
        self.onExit = onExit
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func reset(inside: Bool) {
        isInside = inside
        enteredAt = nil
        leftAt = nil
    }

    private func tick() {
        let inZone = zone().contains(NSEvent.mouseLocation)
        let now = Date()

        if inZone {
            leftAt = nil
            guard !isInside else { return }
            if enteredAt == nil { enteredAt = now }
            if now.timeIntervalSince(enteredAt!) >= enterDelay {
                isInside = true
                enteredAt = nil
                onEnter()
            }
        } else {
            enteredAt = nil
            guard isInside else { return }
            if leftAt == nil { leftAt = now }
            if now.timeIntervalSince(leftAt!) >= exitDelay {
                isInside = false
                leftAt = nil
                onExit()
            }
        }
    }
}
