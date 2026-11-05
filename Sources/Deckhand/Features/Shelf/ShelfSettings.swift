import Foundation
import Combine

/// Settings of the Shelf, in UserDefaults. Shown in Settings → Notch & Panel (`ShelfSection`).
@MainActor
final class ShelfSettings: ObservableObject {
    static let shared = ShelfSettings()
    private let d = UserDefaults.standard

    /// Take files off the shelf once they were dragged somewhere, like a clipboard for files.
    @Published var removeAfterDrag: Bool { didSet { d.set(removeAfterDrag, forKey: "shelfRemoveAfterDrag") } }

    private init() {
        d.register(defaults: ["shelfRemoveAfterDrag": false])
        removeAfterDrag = d.bool(forKey: "shelfRemoveAfterDrag")
    }
}
