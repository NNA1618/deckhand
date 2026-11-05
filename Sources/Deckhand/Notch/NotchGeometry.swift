import AppKit

/// Everything uses one coordinate space: global Cocoa coordinates (origin bottom left),
/// the same space NSEvent.mouseLocation reports.
struct NotchInfo {
    let screen: NSScreen
    /// The notch cutout in global Cocoa coordinates; on a display without one, a virtual notch of the same role.
    let rect: CGRect
    let hasNotch: Bool
    /// Height of the menu-bar band at the top of the screen.
    let menuBarHeight: CGFloat
    /// The screen frame, cached so hot paths don't ask the window server again.
    let screenFrame: CGRect
}

/// What the pure geometry needs to know about a display.
struct ScreenDesc: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    /// `safeAreaInsets.top`: the camera housing's height, 0 without one.
    var safeTop: CGFloat
    /// Widths of the menu-bar areas left and right of the housing, when there is one.
    var auxLeftWidth: CGFloat?
    var auxRightWidth: CGFloat?
    var isBuiltIn: Bool

    var hasNotch: Bool { safeTop > 0 && auxLeftWidth != nil && auxRightWidth != nil }

    /// The real menu-bar height, so a virtual notch matches the bar. An auto-hidden bar reports 0.
    var menuBarHeight: CGFloat {
        if hasNotch { return safeTop }
        let h = frame.maxY - visibleFrame.maxY
        return h > 0 ? h : 24
    }
}

enum NotchGeometry {
    static let virtualNotchWidth: CGFloat = 180

    /// The cutout of a display, or a virtual one centred in its menu bar. Pure.
    static func cutout(of s: ScreenDesc) -> CGRect {
        if s.hasNotch, let left = s.auxLeftWidth, let right = s.auxRightWidth {
            let width = s.frame.width - left - right
            return CGRect(x: s.frame.minX + left, y: s.frame.maxY - s.safeTop, width: width, height: s.safeTop)
        }
        let h = s.menuBarHeight
        return CGRect(x: s.frame.midX - virtualNotchWidth / 2, y: s.frame.maxY - h, width: virtualNotchWidth, height: h)
    }

    /// Index of the display that carries the notch. `screens[0]` is the one with the menu bar. Pure.
    static func choose(_ screens: [ScreenDesc], preference: NotchDisplay, pointer: CGPoint?) -> Int? {
        guard !screens.isEmpty else { return nil }
        switch preference {
        case .builtIn:
            return screens.firstIndex(where: \.hasNotch) ?? screens.firstIndex(where: \.isBuiltIn) ?? 0
        case .main:
            return 0
        case .pointer:
            guard let pointer else { return 0 }
            return screens.firstIndex { ActivationZones.contains($0.frame, pointer) } ?? 0
        }
    }

    @MainActor static func describe(_ screen: NSScreen) -> ScreenDesc {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return ScreenDesc(
            frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width, auxRightWidth: screen.auxiliaryTopRightArea?.width,
            isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        )
    }

    /// The notch to use now, or nil while no display is connected (clamshell during a display change).
    @MainActor static func resolve(preference: NotchDisplay, pointer: CGPoint? = nil) -> NotchInfo? {
        let screens = NSScreen.screens
        let descs = screens.map(describe)
        guard let i = choose(descs, preference: preference, pointer: pointer) else { return nil }
        let d = descs[i]
        return NotchInfo(screen: screens[i], rect: cutout(of: d), hasNotch: d.hasNotch,
                         menuBarHeight: d.menuBarHeight, screenFrame: d.frame)
    }
}
