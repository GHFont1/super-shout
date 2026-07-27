import AppKit

enum DictationState {
    case idle
    case listening(handsFree: Bool)
    case processing
}

/// Coordinates hotkey → record → transcribe → clean → insert.
final class DictationController {
    var onStateChange: ((DictationState) -> Void)?
    private(set) var history: [String] = []

    private let hotkey = HotkeyManager()
    private var transcriber: Transcriber?
    private let injector = TextInjector()
    private let hud = HUDController()
    private var state: DictationState = .idle {
        didSet { onStateChange?(state); hud.update(for: state) }
    }
    private var handsFreeActive = false

    func start() {
        hotkey.onPress = { [weak self] in self?.beginListening(handsFree: false) }
        hotkey.onRelease = { [weak self] in self?.endListening() }
        hotkey.onQuickTap = { [weak self] in self?.toggleHandsFree() }
        hotkey.start()
    }

    private func toggleHandsFree() {
        if handsFreeActive {
            endListening()
        } else {
            handsFreeActive = true
            beginListening(handsFree: true)
        }
    }

    private func beginListening(handsFree: Bool) {
        if case .listening = state {
            if !handsFree { return }  // already listening via press; ignore
            return
        }
        guard case .idle = state else { return }

        let t = Transcriber()
        transcriber = t
        t.onLevel = { [weak self] level in self?.hud.pushLevel(level) }
        t.onPartial = { [weak self] text in self?.hud.showPartial(text) }
        do {
            try t.begin()
            state = .listening(handsFree: handsFree)
        } catch {
            transcriber = nil
            handsFreeActive = false
            hud.flashError(error.localizedDescription)
        }
    }

    private func endListening() {
        guard case .listening = state, let t = transcriber else {
            handsFreeActive = false
            return
        }
        handsFreeActive = false
        state = .processing
        t.finish { [weak self] raw in
            guard let self else { return }
            self.transcriber = nil
            let cleaned = CleanupEngine.clean(raw)
            guard !cleaned.isEmpty else {
                self.state = .idle
                return
            }
            if Settings.shared.aiPolishEnabled, !Settings.shared.anthropicAPIKey.isEmpty {
                ClaudePolish.polish(cleaned) { polished in
                    DispatchQueue.main.async { self.deliver(polished ?? cleaned) }
                }
            } else {
                self.deliver(cleaned)
            }
        }
    }

    private func deliver(_ text: String) {
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast() }
        injector.insert(text)
        state = .idle
    }
}
