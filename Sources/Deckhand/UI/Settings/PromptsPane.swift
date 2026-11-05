import SwiftUI

/// The prompt library. Owned by the prompts, shelf and recents workstream.
struct PromptsPane: View {
    var body: some View {
        SettingsPane(.prompts) {
            Section {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
