import SwiftUI
import AppKit

/// Version, links, system info for bug reports and acknowledgements. Owned by the Settings workstream.
struct AboutPane: View {
    @State private var copied = false

    var body: some View {
        SettingsPane(.about, showsHeader: false) {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text(verbatim: "Deckhand")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.fg)
                    Text("Version \(AppVersion.display)")
                        .font(Theme.body)
                        .foregroundStyle(Theme.fgDim)
                        .textSelection(.enabled)
                    Text("by NNA1618 · MIT License")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.fgMute)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }

            Section {
                SettingsLinkRow(String(localized: "Source code"), icon: .symbol("chevron.left.forwardslash.chevron.right", .gray),
                                to: .url(AboutLinks.repository))
                SettingsLinkRow(String(localized: "Releases"), icon: .symbol("shippingbox.fill", .brown),
                                to: .url(AboutLinks.releases))
                SettingsLinkRow(String(localized: "Report a Problem…"), icon: .symbol("ladybug.fill", .red),
                                to: .url(AboutLinks.newIssue))
                SettingsRow(String(localized: "System info"),
                            detail: String(localized: "Deckhand and macOS versions and the Mac model, for a bug report."),
                            icon: .symbol("info.circle.fill", .blue)) {
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy System Info")) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(SystemInfo.report(), forType: .string)
                        copied = true
                    }
                    .buttonStyle(.settings)
                }
            }

            Section {
                SettingsLinkRow(String(localized: "SQLite.swift by Stephen Celis"), value: String(localized: "MIT License"),
                                to: .url(AboutLinks.sqliteSwift))
            } header: {
                Text("Acknowledgements")
            } footer: {
                SettingsFooter("© 2026 NNA1618. Deckhand is free and open source under the MIT License.")
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

enum AboutLinks {
    static let repository = URL(string: "https://github.com/NNA1618/deckhand")!
    static let releases = URL(string: "https://github.com/NNA1618/deckhand/releases")!
    /// Opens the bug template, which asks for exactly what "Copy System Info" copies.
    static let newIssue = URL(string: "https://github.com/NNA1618/deckhand/issues/new?template=bug_report.md")!
    static let sqliteSwift = URL(string: "https://github.com/stephencelis/SQLite.swift")!
}

/// What the bug report template asks for. In English on purpose: it goes into a GitHub issue.
enum SystemInfo {
    static func report() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return format(version: AppVersion.display,
                      macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                      build: sysctl("kern.osversion"),
                      model: sysctl("hw.model"),
                      language: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func format(version: String, macOS: String, build: String?, model: String?, language: String) -> String {
        [
            "- Deckhand version: \(version)",
            "- macOS version: \(macOS)\(build.map { " (\($0))" } ?? "")",
            "- Mac model: \(model ?? "unknown")",
            "- App language: \(language)",
        ].joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
