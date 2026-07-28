import AppKit

/// Quiet audio feedback for dictation state changes. Volumes are kept low —
/// these are cues, not alerts.
enum SoundCue {
    case listenStart, listenStop, askOpen

    /// Bundled synthesized cues — one glassy instrument across the whole app
    /// so nothing sounds like a stock macOS alert.
    private var resourceName: String {
        switch self {
        case .listenStart: return "listenstart"
        case .listenStop: return "listenstop"
        case .askOpen: return "askopen"
        }
    }

    /// System-sound fallback if the bundled file is ever missing.
    private var fallbackName: String {
        switch self {
        case .listenStart: return "Pop"
        case .listenStop: return "Tink"
        case .askOpen: return "Glass"
        }
    }

    func play() {
        guard Settings.shared.soundCues else { return }
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
           let custom = NSSound(contentsOf: url, byReference: true) {
            custom.volume = 0.5
            custom.play()
            return
        }
        guard let sound = NSSound(named: fallbackName)?.copy() as? NSSound else { return }
        sound.volume = 0.3
        sound.play()
    }
}
