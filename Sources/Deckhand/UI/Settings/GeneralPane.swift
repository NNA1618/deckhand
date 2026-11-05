import SwiftUI
import ServiceManagement

/// Startup, language, menu bar, copied text and resetting. Owned by the Settings workstream.
struct GeneralPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var keepAwake = KeepAwake.shared
    @ObservedObject private var countdown = Countdown.shared
    @State private var loginStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        SettingsPane(.general) {
            Section {
                SettingsToggleRow(String(localized: "Open at login"), isOn: Binding(get: { loginIsOn }, set: { setOpenAtLogin($0) }))
                if loginStatus == .requiresApproval {
                    SettingsRow(String(localized: "Allow Deckhand in Login Items."),
                                icon: .symbol("exclamationmark.triangle.fill", .orange)) {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.settings)
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warn)
                }
            }

            Section {
                ChipPicker(String(localized: "Language"), selection: $settings.appLanguage, options: [
                    ("system", String(localized: "Same as macOS")),
                    ("en", Self.endonym("en")),
                    ("ru", Self.endonym("ru")),
                ])
                if AppRelauncher.needsRestart(chosen: settings.appLanguage, launched: AppRelauncher.languageAtLaunch) {
                    SettingsRow(String(localized: "Restart Deckhand to switch the language."),
                                detail: keepAwake.isActive || countdown.isActive
                                    ? String(localized: "Keep Awake and the timer will stop.") : nil) {
                        Button("Restart Now") { AppRelauncher.relaunch(openSettings: true) }
                            .buttonStyle(.settings(.prominent))
                    }
                }
            }

            Section {
                SettingsToggleRow(String(localized: "Show in the menu bar"), isOn: $settings.showMenuBarIcon)
            } footer: {
                SettingsFooter("Without the icon, open Settings with the gear in the panel or by opening Deckhand again in Finder.")
            }

            Section {
                SettingsToggleRow(String(localized: "Fill in copied text"), isOn: $settings.prefillFromClipboard)
            } footer: {
                SettingsFooter("Translate, Claude and the Recents prompt start with the text you copied, if it looks like ordinary text.")
            }

            Section {
                SettingsLinkRow(String(localized: "Version"), value: AppVersion.display, to: .section(.about))
            }

            SettingsPaneActions {
                ConfirmedButton(
                    title: String(localized: "Reset All Settings…"),
                    alertTitle: String(localized: "Reset all settings?"),
                    message: resetMessage,
                    confirmTitle: String(localized: "Reset"),
                    action: { AppRelauncher.resetAllSettings() }
                )
                .disabled(AppPaths.isSnapshot)
            }
        }
        .onSettingsActivation {
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var resetMessage: String {
        var text = String(localized: "Shortcuts, appearance and other settings go back to the defaults. Clipboard history, prompts and the shelf stay. Deckhand restarts.")
        if AppRelauncher.restartStopsSomething {
            text += " " + String(localized: "Keep Awake and the timer will stop.")
        }
        return text
    }

    /// `requiresApproval` means Deckhand is registered and waits for the user in Login Items.
    private var loginIsOn: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }

    /// A language's name in that language, as macOS shows it in language lists.
    static func endonym(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }
}

/// The version as shown in Settings and copied into bug reports.
enum AppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    /// "0.4.1 (5)".
    static var display: String { "\(short) (\(build))" }
}
