import SwiftUI

/// How the panel opens, closes and looks. Owned by the notch workstream;
/// the Tabs section belongs to the panel workstream.
struct NotchPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPane(.notch) {
            Section {
                Picker("Style", selection: $settings.panelStyle) {
                    Text("Transparent").tag(PanelStyle.clear)
                    Text("Tinted").tag(PanelStyle.tinted)
                    Text("Solid").tag(PanelStyle.solid)
                }
                .pickerStyle(.segmented)
                LabeledContent("Tint") {
                    HStack(spacing: 8) {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                        Slider(value: $settings.glassTint, in: 0...0.8)
                            .frame(width: 220)
                        Image(systemName: "circle.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(settings.panelStyle == .solid)
                Picker("Panel size", selection: $settings.panelSize) {
                    Text("Compact").tag(PanelSize.compact)
                    Text("Standard").tag(PanelSize.standard)
                    Text("Large").tag(PanelSize.large)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Panel")
            } footer: {
                HStack {
                    Text("Transparent shows more of what is behind the panel. Solid turns glass off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Panel") {
                        NotificationCenter.default.post(name: .previewNotchPanel, object: nil)
                    }
                }
            }
            Section {
                Toggle("Open when the pointer rests on the notch", isOn: $settings.openOnHover)
                Picker("Delay", selection: $settings.hoverDelay) {
                    Text("Instant").tag(0.08)
                    Text("Short").tag(0.25)
                    Text("Long").tag(0.5)
                }
                .disabled(!settings.openOnHover)
                Toggle("Stay hidden while an app is in full screen", isOn: $settings.hideInFullScreen)
                Button("Restore Defaults") {
                    settings.panelStyle = .tinted
                    settings.glassTint = 0.38
                    settings.panelSize = .standard
                    settings.openOnHover = true
                    settings.hoverDelay = 0.08
                    settings.hideInFullScreen = true
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Shortcuts and files dragged to the notch open the panel either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TabsSection()
        }
    }
}
