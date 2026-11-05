import AVFoundation

/// Reads the translation aloud with a system voice for its language.
@MainActor
final class TranslationSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Whether macOS has a voice for the language.
    static func canSpeak(_ code: String) -> Bool {
        AVSpeechSynthesisVoice(language: TranslationLanguages.speechIdentifier(for: code)) != nil
    }

    func toggle(_ text: String, language code: String) {
        if isSpeaking {
            stop()
            return
        }
        guard !text.isEmpty, let voice = AVSpeechSynthesisVoice(language: TranslationLanguages.speechIdentifier(for: code))
        else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
