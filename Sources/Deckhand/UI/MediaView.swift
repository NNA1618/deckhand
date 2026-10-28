import SwiftUI

struct MediaView: View {
    @StateObject private var vm = MediaViewModel()

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: 84, height: 84)
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(vm.now.title.isEmpty ? Theme.fgMute : Theme.fg)
                }
                .padding(.bottom, 6)

                if vm.now.title.isEmpty {
                    Text("Nothing is playing").font(Theme.title).foregroundColor(Theme.fgDim)
                    Text("Play still works: it sends the system media key to whatever player you use")
                        .font(Theme.caption).foregroundColor(Theme.fgMute)
                        .multilineTextAlignment(.center)
                } else {
                    Text(vm.now.title)
                        .font(Theme.title).foregroundColor(Theme.fg)
                        .multilineTextAlignment(.center).lineLimit(2)
                    if !vm.now.artist.isEmpty {
                        Text(vm.now.artist).font(Theme.body).foregroundColor(Theme.fgDim)
                    }
                    Text(vm.now.source).font(Theme.caption).foregroundColor(Theme.fgMute)
                }
            }

            HStack(spacing: 14) {
                control("backward.fill", size: 16) { vm.previous() }
                Button { vm.playPause() } label: {
                    Image(systemName: vm.now.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                control("forward.fill", size: 16) { vm.next() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Theme.fg)
                .frame(width: 40, height: 40)
                .glassChip(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch vm.now.source {
        case "Apple Music": return "music.note"
        case "Spotify": return "music.note"
        case "Yandex Music": return "waveform"
        case "YouTube Music", "YouTube": return "play.rectangle"
        default: return "music.note"
        }
    }
}
