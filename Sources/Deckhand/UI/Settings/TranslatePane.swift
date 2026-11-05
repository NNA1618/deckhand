import SwiftUI

/// Translation languages and behavior. Owned by the translate workstream.
struct TranslatePane: View {
    var body: some View {
        SettingsPane(.translate) {
            Section {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
