import AppKit
import SwiftUI

/// Logo assets bundled from Resources/Brand.
enum Brand {
    static let menuBarIcon: NSImage = {
        let image = bundled("MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Deckhand")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Deckhand"
        return image
    }()

    static let markWhite: NSImage? = bundled("mark-white")

    private static func bundled(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// The Deckhand mark, white on the dark panel.
struct BrandMark: View {
    var size: CGFloat = 28
    var body: some View {
        if let mark = Brand.markWhite {
            Image(nsImage: mark).resizable().interpolation(.high).frame(width: size, height: size)
        }
    }
}
