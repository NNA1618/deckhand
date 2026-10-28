import SwiftUI
import Combine

@MainActor
final class MediaViewModel: ObservableObject {
    @Published var now: NowPlaying = .empty

    private let service = MediaInfoService.shared
    private var pollTask: Task<Void, Never>?

    init() {
        poll()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.poll()
            }
        }
    }

    deinit { pollTask?.cancel() }

    func poll() {
        now = service.currentNowPlaying()
    }

    func playPause() {
        MediaController.send(.playPause)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.poll()
        }
    }

    func next() {
        MediaController.send(.next)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    func previous() {
        MediaController.send(.previous)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }
}
