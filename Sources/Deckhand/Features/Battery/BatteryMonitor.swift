import Foundation
import IOKit.ps

/// Reports when the charger is plugged in and when the battery runs low,
/// so the closed notch can show it the way iPhone does.
@MainActor
final class BatteryMonitor {
    static let shared = BatteryMonitor()

    struct State: Equatable {
        var percent: Int
        var onAC: Bool
        var charging: Bool
    }

    enum Event: Equatable {
        case pluggedIn(percent: Int)
        case low(percent: Int)
    }

    /// Called on the main actor for each event.
    var onEvent: (Event) -> Void = { _ in }

    private var source: CFRunLoopSource?
    private var last: State?
    /// Low-battery levels already announced on this discharge.
    private var warned: Set<Int> = []
    static let lowLevels = [20, 10]

    private init() {}

    func start() {
        guard source == nil else { return }
        last = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func update() {
        guard let now = Self.read() else { return }
        let events = Self.events(from: last, to: now, warned: &warned)
        last = now
        events.forEach(onEvent)
    }

    /// What changed between two readings. Separate from IOKit so the self-test can drive it.
    static func events(from old: State?, to new: State, warned: inout Set<Int>) -> [Event] {
        var out: [Event] = []
        if new.onAC {
            warned.removeAll()
            if let old, !old.onAC { out.append(.pluggedIn(percent: new.percent)) }
            return out
        }
        for level in lowLevels where new.percent <= level && !warned.contains(level) {
            // Announce only the lowest level crossed, once
            warned.formUnion(lowLevels.filter { $0 >= level })
            out = [.low(percent: new.percent)]
        }
        return out
    }

    /// The internal battery, or nil on a Mac without one.
    static func read() -> State? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return State(percent: Int((Double(cur) / Double(max) * 100).rounded()), onAC: onAC, charging: charging)
        }
        return nil
    }
}
