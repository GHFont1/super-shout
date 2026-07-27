import AppKit

/// Quiet audio feedback for dictation state changes. Volumes are kept low —
/// these are cues, not alerts.
enum SoundCue {
    case listenStart, listenStop

    private var soundName: String {
        switch self {
        case .listenStart: return "Pop"
        case .listenStop: return "Tink"
        }
    }

    func play() {
        guard Settings.shared.soundCues else { return }
        guard let sound = NSSound(named: soundName)?.copy() as? NSSound else { return }
        sound.volume = 0.3
        sound.play()
    }
}
