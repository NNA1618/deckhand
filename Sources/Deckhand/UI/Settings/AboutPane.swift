import SwiftUI

/// Version, license and links. Owned by the Settings workstream.
struct AboutPane: View {
    var body: some View {
        SettingsPane(.about) {
            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Deckhand by NNA1618. Open source under the MIT license.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
