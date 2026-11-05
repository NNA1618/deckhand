import SwiftUI

/// Shelf settings, shown inside Settings → Notch & Panel. Owned by the prompts, shelf and recents workstream.
struct ShelfSection: View {
    @ObservedObject private var settings = ShelfSettings.shared

    var body: some View {
        Section {
            Toggle("Remove files after dragging them out", isOn: $settings.removeAfterDrag)
        } header: {
            Text("Shelf")
        } footer: {
            Text("The shelf keeps a link to each file, so files stay where they are. Files dragged from a browser or Mail are copied first, because macOS deletes those soon.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
