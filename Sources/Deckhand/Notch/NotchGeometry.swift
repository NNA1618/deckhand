import AppKit

/// Everything uses one coordinate space: global Cocoa coordinates (origin bottom left),
/// the same space NSEvent.mouseLocation reports.
struct NotchInfo {
    let screen: NSScreen
    /// The notch cutout in global Cocoa coordinates.
    let rect: CGRect
    let hasNotch: Bool
}

enum NotchGeometry {
    static func current() -> NotchInfo {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let frame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0
        let height = hasNotch ? screen.safeAreaInsets.top : NSStatusBar.system.thickness

        var width: CGFloat = 200
        var minX = frame.midX - width / 2
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = frame.width - left.width - right.width
            minX = frame.minX + left.width
        }

        let rect = CGRect(x: minX, y: frame.maxY - height, width: width, height: height)
        return NotchInfo(screen: screen, rect: rect, hasNotch: hasNotch)
    }
}
