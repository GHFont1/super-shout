import AppKit
import SwiftUI

enum DictationState {
    case idle
    case listening(handsFree: Bool)
    case processing
}

/// Coordinates hotkey → record → transcribe → clean → insert, in one of three
/// modes depending on which key was held:
/// - Dictate: literal transcription, cleaned locally, inserted at the cursor.
/// - AI Edit: the selection captured at press time is rewritten per the
///   spoken instruction (falls back to Compose when nothing is selected).
/// - AI Compose: the spoken request is turned into finished text by Claude.
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
    private var activeAction: KeyAction = .dictate
    private var capturedSelection: String?

    var canUndo: Bool { injector.lastInserted != nil }

    func start() {
        hotkey.onPress = { [weak self] key in self?.handlePress(key, handsFree: false) }
        hotkey.onRelease = { [weak self] _ in self?.endListening() }
        hotkey.onQuickTap = { [weak self] key in self?.toggleHandsFree(key) }
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

    private func handlePress(_ key: HoldKey, handsFree: Bool) {
        let action = Settings.shared.action(for: key)
        guard action != .off else { return }
        if action.needsAPIKey && Settings.shared.anthropicAPIKey.isEmpty {
            hud.flashError("Add your Anthropic API key in Settings to use AI modes")
            return
        }
        beginListening(action: action, handsFree: handsFree)
    }

    private func toggleHandsFree(_ key: HoldKey) {
        if handsFreeActive {
            endListening()
        } else {
            handsFreeActive = true
            handlePress(key, handsFree: true)
            if case .idle = state, transcriber == nil { handsFreeActive = false }
        }
    }

    private func beginListening(action: KeyAction, handsFree: Bool) {
        if case .listening = state { return }
        if case .processing = state {
            // Previous dictation is still wrapping up. If the user is already
            // holding the key (or toggled hands-free), start the moment we're
            // idle instead of silently dropping their first words.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let stillWanted = handsFree ? self.handsFreeActive : self.hotkey.keyCurrentlyDown
                if stillWanted { self.beginListening(action: action, handsFree: handsFree) }
            }
            return
        }
        guard case .idle = state else { return }

        activeAction = action
        capturedSelection = nil
        if action == .aiEdit {
            // Grab the selection now, while it's still highlighted; dictation
            // runs concurrently with the (possibly async) capture.
            SelectionReader.capture { [weak self] selection in
                self?.capturedSelection = selection
            }
        }

        hud.configureSession(label: sessionLabel(for: action), accent: accent(for: action))

        let t = Transcriber()
        transcriber = t
        t.onLevel = { [weak self] level in self?.hud.pushLevel(level) }
        t.onPartial = { [weak self] text in self?.hud.showPartial(text) }
        do {
            try t.begin()
            state = .listening(handsFree: handsFree)
            NSLog("SuperShout: listening (action=\(action.rawValue), handsFree=\(handsFree))")
        } catch {
            transcriber = nil
            handsFreeActive = false
            NSLog("SuperShout: failed to start listening — \(error.localizedDescription)")
            hud.flashError(error.localizedDescription)
        }
    }

    private func sessionLabel(for action: KeyAction) -> String {
        switch action {
        case .dictate: return "Listening…"
        case .aiEdit: return "AI Edit — say what to change…"
        case .aiCompose: return "AI Compose — say what to write…"
        case .off: return ""
        }
    }

    private func accent(for action: KeyAction) -> Color {
        switch action {
        case .dictate: return .orange
        case .aiEdit: return .purple
        case .aiCompose: return .cyan
        case .off: return .orange
        }
    }

    private func endListening() {
        guard case .listening = state, let t = transcriber else {
            handsFreeActive = false
            return
        }
        handsFreeActive = false
        state = .processing
        let action = activeAction
        t.finish { [weak self] raw in
            guard let self else { return }
            self.transcriber = nil
            switch action {
            case .dictate, .off:
                self.finishDictation(raw)
            case .aiEdit, .aiCompose:
                self.finishAI(raw, action: action)
            }
        }
    }

    private func finishDictation(_ raw: String) {
        let cleaned = CleanupEngine.clean(raw, options: currentCleanOptions())
        NSLog("SuperShout: transcript=\"\(cleaned)\"")
        guard !cleaned.isEmpty else {
            state = .idle
            return
        }
        if Settings.shared.aiPolishEnabled, !Settings.shared.anthropicAPIKey.isEmpty {
            hud.showStatus("Polishing…")
            ClaudePolish.polish(cleaned) { polished in
                DispatchQueue.main.async { self.deliver(polished ?? cleaned) }
            }
        } else {
            deliver(cleaned)
        }
    }

    private func finishAI(_ raw: String, action: KeyAction) {
        // The transcript is an instruction: light cleanup only — no terminal
        // period, no list formatting.
        var opts = CleanupEngine.CleanOptions()
        opts.allowTerminalPunctuation = false
        opts.allowLists = false
        let instruction = CleanupEngine.clean(raw, options: opts)
        guard !instruction.isEmpty else {
            state = .idle
            return
        }
        NSLog("SuperShout: AI instruction=\"\(instruction)\"")
        hud.showStatus("Asking Claude…")

        let complete: (String?) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.deliver(result, raw: true)
                } else {
                    // Never paste the instruction itself on failure.
                    self.state = .idle
                    self.hud.flashError("AI request failed — nothing was inserted")
                }
            }
        }

        if action == .aiEdit, let selection = capturedSelection, !selection.isEmpty {
            ClaudePolish.transform(selection: selection, instruction: instruction, completion: complete)
        } else {
            // AI Edit with nothing selected behaves as Compose.
            ClaudePolish.compose(instruction, completion: complete)
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

    /// `raw: true` pastes the text exactly as produced (AI output replaces a
    /// selection or lands at the cursor without smart-spacing rewrites).
    private func deliver(_ text: String, raw: Bool = false) {
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast() }
        Settings.shared.historyStore = history
        Settings.shared.totalWordsDictated += text.split(whereSeparator: \.isWhitespace).count
        if raw {
            injector.insertRaw(text)
        } else {
            injector.insert(text)
        }
        state = .idle
        hud.flashDone("Inserted")
    }
}
