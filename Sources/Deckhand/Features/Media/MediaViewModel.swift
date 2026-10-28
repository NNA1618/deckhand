import SwiftUI
import Combine

/// Polls what is playing in the background and shares it with the Music tab and the closed notch.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    @Published private(set) var now: NowPlaying = .empty

    private let queue = DispatchQueue(label: "deckhand.nowplaying", qos: .utility)
    private var busy = false
    private var loop: Task<Void, Never>?

    private init() {}

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        queue.async {
            let current = MediaInfoService.shared.currentNowPlaying()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    if self.now != current { self.now = current }
                }
            }
        }
    }
}

@MainActor
final class MediaViewModel: ObservableObject {
    @Published var now: NowPlaying = .empty
    private var cancellable: AnyCancellable?

    init() {
        let monitor = NowPlayingMonitor.shared
        monitor.start()
        now = monitor.now
        cancellable = monitor.$now.receive(on: DispatchQueue.main).sink { [weak self] in self?.now = $0 }
        monitor.refresh()
    }

    func playPause() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }

    private func send(_ key: MediaKey) {
        MediaController.send(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NowPlayingMonitor.shared.refresh() }
    }
}
