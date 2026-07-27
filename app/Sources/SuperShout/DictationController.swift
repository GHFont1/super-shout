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

    /// Terminal apps: list formatting stays off there (a synthetic newline in
    /// a shell prompt can execute a command), but sentence punctuation stays
    /// ON — dictating prose prompts to CLI tools is a primary use.
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
    /// Frontmost app when dictation started — results only auto-paste there.
    private var sessionApp: String?
    /// Human-readable app name at session start, given to the AI as context.
    private var sessionAppName: String?
    private var listenStartedAt: Date?

    var canUndo: Bool { injector.lastInserted != nil }

    func start() {
        hotkey.onPress = { [weak self] key in self?.handlePress(key, handsFree: false) }
        hotkey.onRelease = { [weak self] _ in self?.endListening() }
        hotkey.onQuickTap = { [weak self] key in self?.toggleHandsFree(key) }
        hotkey.onEscape = { [weak self] in self?.cancelListening() }
        hotkey.onMisusedModifier = { [weak self] in
            guard let self, case .idle = self.state else { return }
            self.hud.flashInfo("Use the RIGHT-side keys: Right ⌘ = AI Edit, Right ⌥ = AI Compose, fn = Dictate")
        }
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
        Log.write("handlePress: key=\(key.rawValue) action=\(action.rawValue) state=\(state) configured=\(ClaudePolish.isConfigured)")
        guard action != .off else { return }
        if action.needsAPIKey && !ClaudePolish.isConfigured {
            hud.flashError("Set up an AI provider in Settings to use AI modes")
            return
        }
        beginListening(action: action, handsFree: handsFree)
    }

    private func toggleHandsFree(_ key: HoldKey) {
        guard Settings.shared.handsFreeTap else {
            // Hands-free latch is off: the press already started listening, so
            // a tap just ends that too-short session (empty transcript, no-op).
            endListening()
            return
        }
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
        sessionApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sessionAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        if action == .aiEdit {
            // Grab the selection now, while it's still highlighted; dictation
            // runs concurrently with the (possibly async) capture.
            SelectionReader.capture { [weak self] selection in
                self?.capturedSelection = selection
                Log.write("selection captured: \(selection?.count ?? 0) chars")
            }
        }

        hud.configureSession(label: sessionLabel(for: action), accent: accent(for: action))

        let t = Transcriber()
        transcriber = t
        t.onLevel = { [weak self] level in self?.hud.pushLevel(level) }
        t.onPartial = { [weak self] text in self?.hud.showPartial(text) }
        do {
            try t.begin()
            listenStartedAt = Date()
            SoundCue.listenStart.play()
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
        SoundCue.listenStop.play()
        if let started = listenStartedAt {
            Settings.shared.totalSecondsDictated += Date().timeIntervalSince(started)
            listenStartedAt = nil
        }
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
        var cleaned = CleanupEngine.clean(raw, options: currentCleanOptions())
        // Spoken "press enter" at the end sends the message after inserting —
        // chat boxes, terminal prompts, AI chats.
        var pressEnter = false
        if Settings.shared.spokenCommands,
           let r = cleaned.range(of: #"(?i)[,.!?]?\s*\bpress enter\b[.!?]?\s*$"#, options: .regularExpression) {
            cleaned.removeSubrange(r)
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            pressEnter = true
        }
        Log.write("transcript: \"\(cleaned.prefix(80))\" (\(cleaned.count) chars) pressEnter=\(pressEnter)")
        guard !cleaned.isEmpty else {
            if pressEnter { injector.pressReturn() }
            state = .idle
            if pressEnter { hud.flashDone("Sent") }
            return
        }
        if Settings.shared.aiPolishEnabled, ClaudePolish.isConfigured {
            hud.showStatus("Polishing…")
            // Polish must never make dictation feel slow: if it hasn't come
            // back in 5 s, insert the local cleanup and drop the late result.
            var delivered = false
            let fallback = DispatchWorkItem { [weak self] in
                guard let self, !delivered else { return }
                delivered = true
                Log.write("polish deadline hit — inserting local cleanup")
                self.deliver(cleaned, pressEnter: pressEnter)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: fallback)
            ClaudePolish.polish(cleaned, appName: sessionAppName) { polished in
                DispatchQueue.main.async {
                    guard !delivered else { return }
                    delivered = true
                    fallback.cancel()
                    self.deliver(polished ?? cleaned, pressEnter: pressEnter)
                }
            }
        } else {
            deliver(cleaned, pressEnter: pressEnter)
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
        Log.write("AI instruction (\(action.rawValue)): \"\(instruction.prefix(80))\" selection=\(capturedSelection?.count ?? 0) chars")
        hud.showStatus("Asking Claude…")

        let complete: (String?) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                Log.write("AI result: \(result.map { "\($0.count) chars" } ?? "FAILED")")
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
            ClaudePolish.compose(instruction, appName: sessionAppName, completion: complete)
        }
    }

    /// Tailors cleanup to where the text is going: search fields get no
    /// terminal period (queries aren't sentences); terminals keep sentence
    /// punctuation but never get synthetic newlines.
    private func currentCleanOptions() -> CleanupEngine.CleanOptions {
        var opts = CleanupEngine.CleanOptions()
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let codeSafe = Self.codeSafeApps.contains(bundleID)
        let searchField = ContextReader.isSearchFieldFocused()
        opts.allowTerminalPunctuation = !searchField
        opts.allowLists = !searchField && !codeSafe
        opts.stripTrailingPeriod = searchField
        Log.write("cleanOptions: app=\(bundleID) codeSafe=\(codeSafe) searchField=\(searchField)")
        return opts
    }

    /// `raw: true` pastes the text exactly as produced (AI output replaces a
    /// selection or lands at the cursor without smart-spacing rewrites).
    private func deliver(_ text: String, raw: Bool = false, pressEnter: Bool = false) {
        history.insert(text, at: 0)
        if history.count > 25 { history.removeLast() }
        Settings.shared.historyStore = history
        Settings.shared.totalWordsDictated += text.split(whereSeparator: \.isWhitespace).count

        let currentApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sameApp = sessionApp == nil || currentApp == sessionApp
        let editable = ContextReader.focusIsEditable()
        Log.write("deliver: \(text.count) chars raw=\(raw) sameApp=\(sameApp) editable=\(editable) app=\(currentApp ?? "?")")

        // A synthetic paste only lands when the same app is frontmost and the
        // focus can take text. AI results arrive seconds later — if either
        // check fails, hand the user the result instead of pasting into the
        // void and claiming success.
        if raw && (!sameApp || !editable) {
            injector.copyOnly(text)
            state = .idle
            hud.flashInfo(!sameApp
                ? "Result copied — press ⌘V where you want it"
                : "That text isn't editable — result copied, press ⌘V to paste it anywhere")
            return
        }

        if raw {
            injector.insertRaw(text)
        } else {
            injector.insert(text)
        }
        if pressEnter { injector.pressReturn(after: 0.35) }
        state = .idle
        hud.flashDone(pressEnter ? "Sent" : "Inserted")
    }
}
