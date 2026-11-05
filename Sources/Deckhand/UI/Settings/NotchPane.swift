import SwiftUI

/// How the panel opens, closes and looks, and which display carries it. Owned by the notch workstream;
/// the Tabs section belongs to the panel workstream.
struct NotchPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var notch = NotchSettings.shared

    var body: some View {
        SettingsPane(.notch) {
            Section {
                Picker("Open the panel", selection: $notch.activation) {
                    Text("When the pointer rests on the notch").tag(PanelActivation.hover)
                    Text("When I click the notch").tag(PanelActivation.click)
                    Text("On hover or click").tag(PanelActivation.hoverAndClick)
                    Text("Only with the shortcut").tag(PanelActivation.shortcut)
                }
                if notch.activation.opensOnHover {
                    Picker("Hover delay", selection: $notch.hoverDelay) {
                        ForEach(NotchSettings.hoverDelays, id: \.self) { Text(verbatim: SettingsFormat.seconds($0)).tag($0) }
                    }
                }
                if notch.activation != .shortcut {
                    ChipPicker(String(localized: "Hover area"), selection: $notch.hoverArea, options: [
                        (HoverArea.narrow, String(localized: "hoverArea.narrow", defaultValue: "Narrow")),
                        (HoverArea.standard, String(localized: "hoverArea.standard", defaultValue: "Standard")),
                        (HoverArea.wide, String(localized: "hoverArea.wide", defaultValue: "Wide")),
                    ])
                }
                if notch.activation.opensOnHover {
                    SettingsToggleRow(String(localized: "Haptic feedback"), isOn: $notch.hapticOnOpen)
                }
                SettingsToggleRow(String(localized: "Don't open over full-screen apps"), isOn: $settings.hideInFullScreen)
                SettingsToggleRow(String(localized: "Open the Shelf when files are dragged to the notch"), isOn: $notch.dragOpensShelf)
            } header: {
                Text("Opening")
            } footer: {
                SettingsFooter("The panel opens when the pointer stops on the notch, not when it passes by. The shortcut opens it in any mode.")
            }

            Section {
                Picker(String(localized: "notch.closeThePanel", defaultValue: "Close the panel"), selection: $notch.closeOnPointerExit) {
                    Text("When the pointer leaves").tag(true)
                    Text("On click outside or Esc").tag(false)
                }
                if notch.closeOnPointerExit {
                    Picker("Close delay", selection: $notch.closeDelay) {
                        ForEach(NotchSettings.closeDelays, id: \.self) { Text(verbatim: SettingsFormat.seconds($0)).tag($0) }
                    }
                }
            } header: {
                Text("Closing")
            } footer: {
                SettingsFooter("Esc, the shortcut and a click outside always close it.")
            }

            Section {
                ChipPicker(String(localized: "Style"), selection: $settings.panelStyle, options: [
                    // Own keys: the shared "Clear" and "Solid" entries mean other things in Russian
                    (PanelStyle.clear, String(localized: "panelStyle.clear", defaultValue: "Clear")),
                    (PanelStyle.tinted, String(localized: "Tinted")),
                    (PanelStyle.solid, String(localized: "panelStyle.solid", defaultValue: "Solid")),
                ])
                if settings.panelStyle != .solid {
                    SettingsRow(String(localized: "Tint")) {
                        HStack(spacing: 8) {
                            Image(systemName: "circle").foregroundStyle(Theme.fgMute)
                            Slider(value: $settings.glassTint, in: 0...0.8)
                                .frame(width: 200)
                            Image(systemName: "circle.fill").foregroundStyle(Theme.fgMute)
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                ChipPicker(String(localized: "Size"), selection: $settings.panelSize, options: [
                    (PanelSize.compact, String(localized: "Compact")),
                    (PanelSize.standard, String(localized: "Standard")),
                    (PanelSize.large, String(localized: "Large")),
                ])
                SettingsRow(String(localized: "Preview")) {
                    Button("Preview on Screen") {
                        NotificationCenter.default.post(name: .previewNotchPanel, object: nil)
                    }
                    .buttonStyle(.settings)
                }
            } header: {
                Text("Look")
            } footer: {
                SettingsFooter(Self.liquidGlass
                     ? LocalizedStringKey("Clear shows more of what is behind the panel. Solid turns glass off.")
                     : LocalizedStringKey("Liquid Glass needs macOS 26. On this Mac the panel uses a blur."))
            }

            TabsSection()
            ShelfSection()

            Section {
                Picker("Display", selection: $notch.display) {
                    Text("Built-in").tag(NotchDisplay.builtIn)
                    Text("Main (with the menu bar)").tag(NotchDisplay.main)
                    Text("The one with the pointer").tag(NotchDisplay.pointer)
                }
                Picker("Without a notch", selection: $notch.noNotchStyle) {
                    Text("Black pill").tag(NoNotchStyle.blackPill)
                    Text("Nothing until hovered").tag(NoNotchStyle.invisible)
                }
            } header: {
                Text("Displays")
            } footer: {
                SettingsFooter("Used when the lid is closed or a display has no notch.")
            }

            SettingsPaneActions {
                RestoreDefaultsButton(section: .notch,
                                      message: String(localized: "Opening, closing, look and displays go back to the defaults. Tabs stay as they are.")) {
                    notch.restoreDefaults()
                }
            }
        }
    }

    private static var liquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

/// Numbers with units in the app's language ("0.2 sec" / «0,2 с», "2 seconds" / «2 секунды»).
@MainActor
enum SettingsFormat {
    static func seconds(_ value: Double, wide: Bool = false) -> String {
        Measurement(value: value, unit: UnitDuration.seconds).formatted(
            .measurement(width: wide ? .wide : .abbreviated, usage: .asProvided,
                         numberFormatStyle: .number.precision(.fractionLength(0...2)))
            .locale(BadgeText.locale))
    }
}
