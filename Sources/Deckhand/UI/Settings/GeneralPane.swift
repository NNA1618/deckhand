import SwiftUI
import ServiceManagement

/// Startup, language and version. Owned by the Settings workstream.
struct GeneralPane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsPane(.general) {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = on
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Picker("Language", selection: Binding(
                    get: { settings.appLanguage },
                    set: { lang in
                        guard lang != settings.appLanguage else { return }
                        settings.appLanguage = lang
                        AppRelauncher.relaunch(openSettings: true)
                    }
                )) {
                    Text("Same as macOS").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Deckhand restarts to switch the language. Deckhand by NNA1618, open source under the MIT license.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
