import SwiftUI
import AppKit

/// The Music tab: what plays now, with artwork, progress, controls and a picker when several sources play.
struct MediaView: View {
    @ObservedObject private var monitor = NowPlayingMonitor.shared
    @ObservedObject private var media = MediaSettings.shared

    var body: some View {
        Group {
            if !media.enabled {
                off
            } else {
                player
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.viewerAppeared() }
        .onDisappear { monitor.viewerDisappeared() }
    }

    // MARK: - States

    private var off: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note").font(.system(size: 26, weight: .light)).foregroundColor(Theme.fgMute)
            Text("Now playing is off").font(Theme.body).foregroundColor(Theme.fgDim)
            PrimaryButton(title: "Turn On") { media.enabled = true }
            Spacer()
        }
    }

    private var player: some View {
        let item = monitor.selected
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 24) {
                ArtworkTile(item: item, image: item.app.flatMap { monitor.artwork[$0] })
                VStack(alignment: .leading, spacing: 0) {
                    details(item)
                    if let duration = item.duration, item.app != nil {
                        ProgressLine(item: item, duration: duration)
                            .padding(.top, 14)
                    }
                    controls(item)
                        .padding(.top, 16)
                    if let notice = notice(for: item) {
                        notice.padding(.top, 14)
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
            if monitor.sources.count > 1 {
                SourcePicker(sources: monitor.sources, selected: item.app) { monitor.pinned = $0 }
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func details(_ item: NowPlaying) -> some View {
        if let app = item.app {
            HStack(spacing: 6) {
                AppIcon(app: app).frame(width: 14, height: 14).foregroundColor(Theme.fgMute)
                Text(item.sourceDetail)
                    .font(Theme.caption).foregroundColor(Theme.fgMute)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.bottom, 6)
            if item.title.isEmpty {
                // The track isn't known: the line above says who plays, this says whether it plays
                Group {
                    if !item.isPlaying { Text("Paused") }
                    else if app.kind == .browser { Text("Playing sound") }
                    else { Text("Playing") }
                }
                .font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.fg)
            } else {
                Text(item.title)
                    .font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.fg)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.artist.isEmpty || !item.album.isEmpty {
                    Text(item.album.isEmpty ? item.artist : item.artist.isEmpty ? item.album : "\(item.artist) — \(item.album)")
                        .font(Theme.body).foregroundColor(Theme.fgDim)
                        .lineLimit(1)
                        .padding(.top, 3)
                }
            }
        } else {
            Text("Nothing is playing")
                .font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.fg)
            Text("Apple Music, Spotify, Yandex Music and music sites in Safari, Chrome and Edge show up here.")
                .font(Theme.caption).foregroundColor(Theme.fgMute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func controls(_ item: NowPlaying) -> some View {
        HStack(spacing: 14) {
            control("backward.fill", label: "Previous") { monitor.previous() }
            Button { monitor.playPause() } label: {
                Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.accent))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isPlaying ? Text("Pause") : Text("Play"))
            control("forward.fill", label: "Next") { monitor.next() }
        }
    }

    private func control(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.fg)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .glassChip(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    /// A permission or control problem for this source, with the button that fixes it.
    private func notice(for item: NowPlaying) -> NoticeRow? {
        if let problem = monitor.controlProblem {
            switch problem {
            case .needsAccessibility:
                return NoticeRow(text: "To control browsers, Deckhand needs Accessibility.", button: "Allow…") {
                    MediaController.requestAccessibility()
                    monitor.clearControlProblem()
                }
            case .needsAutomation(let app):
                return NoticeRow(text: "Allow Deckhand to control \(app.displayName) in System Settings → Automation.",
                                 button: "Open") {
                    MediaController.openPrivacySettings("Privacy_Automation")
                    monitor.clearControlProblem()
                }
            case .sent:
                break
            }
        }
        guard let app = item.app, item.title.isEmpty, let blocker = monitor.blocked[app] else { return nil }
        switch blocker {
        case .automationNotAsked:
            return NoticeRow(text: "Allow Deckhand to read the tab title to see the track.", button: "Allow…") {
                monitor.allowAutomation(app)
            }
        case .automationDenied:
            return NoticeRow(text: "Reading \(app.displayName) tabs is turned off in System Settings → Automation.",
                             button: "Open") {
                MediaController.openPrivacySettings("Privacy_Automation")
            }
        case .accessibility:
            return NoticeRow(text: "To read the track from Yandex Music, Deckhand needs Accessibility.", button: "Allow…") {
                MediaController.requestAccessibility()
            }
        }
    }
}

/// One line of explanation with a button, inside the Music tab.
private struct NoticeRow: View {
    let text: LocalizedStringKey
    let button: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(Theme.fgMute)
            Text(text)
                .font(Theme.caption).foregroundColor(Theme.fgDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            GlassButton(title: button, action: action).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
    }
}

/// The album artwork, or the source's symbol on a soft tile when there is none.
private struct ArtworkTile: View {
    let item: NowPlaying
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface2)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(item.app == nil ? Theme.fgMute : Theme.fgDim)
            }
        }
        .frame(width: 168, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch item.site {
        case .youtube: return "play.rectangle"
        case .soundcloud, .yandexMusic, .youtubeMusic, .vk: return "waveform"
        case nil: return item.app?.kind == .browser ? "speaker.wave.2" : "music.note"
        }
    }
}

/// Elapsed time, a bar, and the time left. Ticks once a second, and only while playing.
private struct ProgressLine: View {
    let item: NowPlaying
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = item.position(at: item.isPlaying ? context.date : (item.positionDate ?? context.date))
            VStack(spacing: 5) {
                GeometryReader { geo in
                    let fraction = position.map { min(max($0 / duration, 0), 1) } ?? 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule().fill(Theme.fgDim).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(position.map(Self.format) ?? "–:––")
                    Spacer()
                    Text("−" + Self.format(max(duration - (position ?? 0), 0)))
                }
                .font(Theme.monoSmall).foregroundColor(Theme.fgMute)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Progress"))
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Chips for every source that has something to show, when there is more than one.
private struct SourcePicker: View {
    let sources: [NowPlaying]
    let selected: MediaApp?
    let pick: (MediaApp?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sources, id: \.app) { item in
                let active = item.app == selected
                Button { pick(item.app) } label: {
                    HStack(spacing: 5) {
                        if let app = item.app { AppIcon(app: app).frame(width: 13, height: 13) }
                        Text(item.source).lineLimit(1)
                        if item.isPlaying {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                        }
                    }
                    .font(Theme.label)
                    .foregroundColor(active ? .black : Theme.fgDim)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(active ? Theme.accent : Theme.surface2))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

/// The app's own icon, or a symbol when it isn't installed.
struct AppIcon: View {
    let app: MediaApp

    var body: some View {
        if let icon = Self.icon(for: app) {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "music.note").resizable().aspectRatio(contentMode: .fit)
        }
    }

    @MainActor private static var cache: [MediaApp: NSImage] = [:]

    @MainActor static func icon(for app: MediaApp) -> NSImage? {
        if let cached = cache[app] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[app] = icon
        return icon
    }
}
