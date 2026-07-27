import AppKit

enum DictationState {
    case idle
    case listening(handsFree: Bool)
    case processing
}

/// Coordinates hotkey → record → transcribe → clean → insert.
final class DictationController {
    var onStateChange: ((DictationState) -> Void)?
    private(set) var history: [String] = Settings.shared.historyStore

    /// Apps where dictation must stay literal: no auto-punctuation or list
    /// formatting in a shell prompt.
    private static let codeSafeApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm"
    ]

    private let hotkey = HotkeyManager()
    private var transcriber: Transcriber?
    private let injector = TextInjector()
    private let hud = HUDController()
    private var state: DictationState = .idle {
        didSet { onStateChange?(state); hud.update(for: state) }
    }
    private var handsFreeActive = false

    var canUndo: Bool { injector.lastInserted != nil }

    func start() {
        hotkey.onPress = { [weak self] in self?.beginListening(handsFree: false) }
        hotkey.onRelease = { [weak self] in self?.endListening() }
        hotkey.onQuickTap = { [weak self] in self?.toggleHandsFree() }
        hotkey.onEscape = { [weak self] in self?.cancelListening() }
        hotkey.isListening = { [weak self] in
            if case .listening = self?.state { return true }
            return false
        }
        hotkey.start()
    }

    /// Aborts the current dictation without inserting anything (Esc).
    func cancelListening() {
        guard case .listening = state else { return }
        transcriber?.cancel()
        transcriber = nil
        handsFreeActive = false
        state = .idle
        hud.flashDone("Canceled")
        NSLog("SuperShout: dictation canceled")
    }

    /// Deletes the most recent insertion from the focused field.
    func undoLastInsertion() {
        injector.undoLastInsertion()
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
        if case .processing = state {
            // Previous dictation is still wrapping up. If the user is already
            // holding the key (or toggled hands-free), start the moment we're
            // idle instead of silently dropping their first words.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let stillWanted = handsFree ? self.handsFreeActive : self.hotkey.keyCurrentlyDown
                if stillWanted { self.beginListening(handsFree: handsFree) }
            }
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
            NSLog("SuperShout: listening (handsFree=\(handsFree))")
        } catch {
            transcriber = nil
            handsFreeActive = false
            NSLog("SuperShout: failed to start listening — \(error.localizedDescription)")
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
            let cleaned = CleanupEngine.clean(raw, options: self.currentCleanOptions())
            NSLog("SuperShout: transcript=\"\(cleaned)\"")
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

    /// Tailors cleanup to where the text is going: search fields get no
    /// terminal period (queries aren't sentences), terminals get literal text.
    private func currentCleanOptions() -> CleanupEngine.CleanOptions {
        var opts = CleanupEngine.CleanOptions()
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let codeSafe = Self.codeSafeApps.contains(bundleID)
        let searchField = ContextReader.isSearchFieldFocused()
        opts.allowTerminalPunctuation = !searchField && !codeSafe
        opts.allowLists = !searchField && !codeSafe
        opts.stripTrailingPeriod = searchField
        return opts
    }

    private func deliver(_ text: String) {
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast() }
        Settings.shared.historyStore = history
        Settings.shared.totalWordsDictated += text.split(whereSeparator: \.isWhitespace).count
        injector.insert(text)
        state = .idle
        hud.flashDone("Inserted")
    }
}
