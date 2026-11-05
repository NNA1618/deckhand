import SwiftUI

/// Now playing sources and the music badge. Owned by the media workstream.
struct MusicPane: View {
    var body: some View {
        SettingsPane(.music) {
            Section {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
