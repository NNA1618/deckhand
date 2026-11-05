import SwiftUI

/// Screenshots, text from the screen, the color picker and the editor. Owned by the capture and hotkeys workstream.
struct CapturePane: View {
    var body: some View {
        SettingsPane(.capture) {
            Section {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
