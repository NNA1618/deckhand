import SwiftUI

/// Permission status and where data lives. Owned by the Settings workstream.
struct PermissionsPane: View {
    var body: some View {
        SettingsPane(.permissions) {
            Section {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
