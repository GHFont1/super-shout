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
    private var activeEngine: EngineChoice = .auto
    private var capturedSelection: String?
    /// Frontmost app when dictation started — results only auto-paste there.
    private var sessionApp: String?
    /// Human-readable app name at session start, given to the AI as context.
    private var sessionAppName: String?
    private var sessionMode: AppMode?
    private var listenStartedAt: Date?
    private var sessionDuration: TimeInterval?

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
        if activeAction == .aiAsk { AskWindowController.shared.endLive() }
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
        let engine = Settings.shared.engine(for: key)
        Log.write("handlePress: key=\(key.rawValue) action=\(action.rawValue) engine=\(engine.rawValue) state=\(state)")
        guard action != .off else { return }
        if action.needsAPIKey && !ClaudePolish.isConfigured(for: engine) {
            hud.flashError("That key's engine isn't set up — check the AI provider in Settings")
            return
        }
        beginListening(action: action, engine: engine, handsFree: handsFree)
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

    private func beginListening(action: KeyAction, engine: EngineChoice = .auto, handsFree: Bool) {
        if case .listening = state { return }
        if case .processing = state {
            // Previous dictation is still wrapping up. If the user is already
            // holding the key (or toggled hands-free), start the moment we're
            // idle instead of silently dropping their first words.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                let stillWanted = handsFree ? self.handsFreeActive : self.hotkey.keyCurrentlyDown
                if stillWanted { self.beginListening(action: action, engine: engine, handsFree: handsFree) }
            }
            return
        }
        guard case .idle = state else { return }

        activeAction = action
        activeEngine = engine
        capturedSelection = nil
        sessionApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sessionAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        sessionMode = AppModeResolver.resolve(bundleIdentifier: sessionApp, modes: Settings.shared.appModes)
        if let sessionMode { Log.write("automatic mode: \(sessionMode.name) for \(sessionApp ?? "?")") }
        if action == .aiEdit || action == .aiAgent || action == .aiAsk {
            // Grab the selection now, while it's still highlighted; dictation
            // runs concurrently with the (possibly async) capture.
            SelectionReader.capture { [weak self] selection in
                self?.capturedSelection = selection
                Log.write("selection captured: \(selection?.count ?? 0) chars")
            }
        }

        hud.configureSession(label: sessionLabel(for: action), accent: accent(for: action))
        if action == .aiAsk {
            // The Ask panel pulls down immediately and shows the words live —
            // the conversation surface is visible before the first word lands.
            AskWindowController.shared.beginLive(engine: engine)
        }

        let t = Transcriber()
        transcriber = t
        t.onLevel = { [weak self] level in self?.hud.pushLevel(level) }
        t.onPartial = { [weak self] text in
            guard let self else { return }
            self.hud.showPartial(text)
            if self.activeAction == .aiAsk { AskWindowController.shared.updatePartial(text) }
        }
        do {
            try t.begin()
            listenStartedAt = Date()
            SoundCue.listenStart.play()
            state = .listening(handsFree: handsFree)
            NSLog("SuperShout: listening (action=\(action.rawValue), handsFree=\(handsFree))")
        } catch {
            transcriber = nil
            handsFreeActive = false
            if action == .aiAsk { AskWindowController.shared.endLive() }
            NSLog("SuperShout: failed to start listening — \(error.localizedDescription)")
            hud.flashError(error.localizedDescription)
        }
    }

    private func sessionLabel(for action: KeyAction) -> String {
        switch action {
        case .dictate: return "Listening…"
        case .aiRewrite: return "AI Rewrite — speak freely, it types it your way…"
        case .aiDeep: return "Deep Research — say what to look up and write…"
        case .aiAgent: return "AI Do — say what to do (with the selection)…"
        case .aiAsk: return "AI Ask — ask anything…"
        case .aiEdit: return "AI Edit — say what to change…"
        case .aiCompose: return "AI Compose — say what to write…"
        case .off: return ""
        }
    }

    private func accent(for action: KeyAction) -> Color {
        switch action {
        case .dictate: return .orange
        case .aiRewrite: return .green
        case .aiDeep: return .indigo
        case .aiAgent: return .pink
        case .aiAsk: return .mint
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
            sessionDuration = Date().timeIntervalSince(started)
            Settings.shared.totalSecondsDictated += sessionDuration ?? 0
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
            case .aiRewrite:
                self.finishRewrite(raw)
            case .aiEdit, .aiCompose:
                self.finishAI(raw, action: action)
            case .aiDeep:
                self.finishDeep(raw)
            case .aiAgent:
                self.finishAgent(raw)
            case .aiAsk:
                self.finishAsk(raw)
            }
        }
    }

    private func finishDictation(_ raw: String) {
        let expanded = SnippetExpander.expand(raw, snippets: Settings.shared.voiceSnippets)
        var cleaned = CleanupEngine.clean(expanded, options: currentCleanOptions())
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
        VoiceTutor.record(cleaned)
        guard !cleaned.isEmpty else {
            if pressEnter { injector.pressReturn() }
            state = .idle
            if pressEnter { hud.flashDone("Sent") }
            return
        }
        let shouldPolish = sessionMode?.aiPolish ?? Settings.shared.aiPolishEnabled
        if shouldPolish, ClaudePolish.isConfigured {
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
            ClaudePolish.polish(cleaned, appName: sessionAppName, engine: activeEngine) { polished in
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

    /// AI Rewrite: the whole transcript is retyped in the user's voice,
    /// formatted for the destination. On AI failure the cleaned literal
    /// dictation is inserted instead — speech is never lost.
    /// Deep research runs for minutes, so it never holds the dictation state:
    /// it launches in the background, dictation returns to idle immediately,
    /// and the finished deliverable arrives on the clipboard + history.
    private func finishDeep(_ raw: String) {
        var opts = CleanupEngine.CleanOptions()
        opts.allowTerminalPunctuation = false
        opts.allowLists = false
        let instruction = CleanupEngine.clean(raw, options: opts)
        guard !instruction.isEmpty else {
            state = .idle
            return
        }
        guard ClaudePolish.isDeepAvailable(for: activeEngine) else {
            state = .idle
            hud.flashError("Deep Research needs that key's CLI engine installed")
            return
        }
        Log.write("DEEP instruction: \"\(instruction.prefix(120))\"")
        state = .idle
        let engineLabel = ClaudePolish.resolvedEngineLabel(for: activeEngine)
        let task = ActivityCenter.shared.begin(kind: "Deep Research · \(engineLabel)", title: instruction)
        ClaudePolish.deepResearch(instruction, engine: activeEngine, onProgress: { line in
            ActivityCenter.shared.update(task, line)
        }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                ActivityCenter.shared.finish(task, report: result)
                if let result {
                    self.history.insert(result, at: 0)
                    if self.history.count > 25 { self.history.removeLast() }
                    Settings.shared.historyStore = self.history
                    TranscriptHistory.shared.add(TranscriptRecord(text: result, rawText: instruction, kind: .research, appName: self.sessionAppName, bundleIdentifier: self.sessionApp, modeName: self.sessionMode?.name, duration: self.sessionDuration))
                    self.injector.copyOnly(result)
                    SoundCue.listenStop.play()
                    self.hud.flashInfo("Deep research done — result copied, press ⌘V (also in Recent Transcripts)")
                } else {
                    self.hud.flashError("Deep research failed — see ~/Library/Logs/SuperShout.log")
                }
            }
        }
    }

    /// AI Do: hand the instruction (+ any selection) to a background agent
    /// that actually performs the task, then report what happened. Never
    /// blocks dictation while it works.
    private func finishAgent(_ raw: String) {
        var opts = CleanupEngine.CleanOptions()
        opts.allowTerminalPunctuation = false
        opts.allowLists = false
        let instruction = CleanupEngine.clean(raw, options: opts)
        guard !instruction.isEmpty else {
            state = .idle
            return
        }
        guard ClaudePolish.isDeepAvailable(for: activeEngine) else {
            state = .idle
            hud.flashError("AI Do needs that key's CLI engine installed")
            return
        }
        let selection = capturedSelection
        Log.write("AGENT instruction: \"\(instruction.prefix(120))\" selection=\(selection?.count ?? 0) chars")
        state = .idle
        let engineLabel = ClaudePolish.resolvedEngineLabel(for: activeEngine)
        ActivityCenter.shared.agentEngine = activeEngine
        let task = ActivityCenter.shared.begin(kind: "AI Do · \(engineLabel)", title: instruction)
        ClaudePolish.agentAct(instruction: instruction, selection: selection, engine: activeEngine, onProgress: { line in
            ActivityCenter.shared.update(task, line)
        }) { [weak self] report in
            DispatchQueue.main.async {
                guard let self else { return }
                ActivityCenter.shared.finish(task, report: report)
                if let report {
                    self.history.insert(report, at: 0)
                    if self.history.count > 25 { self.history.removeLast() }
                    Settings.shared.historyStore = self.history
                    TranscriptHistory.shared.add(TranscriptRecord(text: report, rawText: instruction, kind: .action, appName: self.sessionAppName, bundleIdentifier: self.sessionApp, modeName: self.sessionMode?.name, duration: self.sessionDuration))
                    SoundCue.listenStop.play()
                    self.hud.flashInfo("Done: \(report.prefix(90))")
                } else {
                    self.hud.flashError("AI Do failed — see ~/Library/Logs/SuperShout.log")
                }
            }
        }
    }

    /// AI Ask: the question opens the chat window and the answer lands there —
    /// nothing is typed into the focused app.
    private func finishAsk(_ raw: String) {
        var opts = CleanupEngine.CleanOptions()
        opts.allowLists = false
        let question = CleanupEngine.clean(raw, options: opts)
        guard !question.isEmpty else {
            AskWindowController.shared.endLive()
            state = .idle
            return
        }
        let selection = capturedSelection
        Log.write("ASK: \"\(question.prefix(100))\" selection=\(selection?.count ?? 0) chars")
        state = .idle
        AskWindowController.shared.ask(question, selection: selection, engine: activeEngine)
    }

    private func finishRewrite(_ raw: String) {
        // Keep punctuation so the model sees sentence boundaries; skip local
        // list formatting — structure is the model's job here.
        var opts = CleanupEngine.CleanOptions()
        opts.allowLists = false
        var cleaned = CleanupEngine.clean(raw, options: opts)
        var pressEnter = false
        if Settings.shared.spokenCommands,
           let r = cleaned.range(of: #"(?i)[,.!?]?\s*\bpress enter\b[.!?]?\s*$"#, options: .regularExpression) {
            cleaned.removeSubrange(r)
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            pressEnter = true
        }
        guard !cleaned.isEmpty else {
            state = .idle
            return
        }
        Log.write("rewrite transcript: \"\(cleaned.prefix(80))\" (\(cleaned.count) chars)")
        hud.showStatus("Rewriting in your voice…")
        VoiceTutor.record(cleaned)
        ClaudePolish.rewrite(cleaned, appName: sessionAppName, engine: activeEngine) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                Log.write("rewrite result: \(result.map { "\($0.count) chars" } ?? "FAILED — falling back to literal")")
                if let result {
                    self.deliver(result, raw: true, pressEnter: pressEnter)
                } else {
                    self.deliver(cleaned, pressEnter: pressEnter)
                    self.hud.flashInfo("AI unavailable — inserted as spoken")
                }
            }
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
        let resolvedEngine = ClaudePolish.resolvedEngineLabel(for: activeEngine)
        Log.write("AI resolved engine: \(resolvedEngine)")
        hud.showStatus("Asking \(resolvedEngine)…")

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
            ClaudePolish.transform(selection: selection, instruction: instruction, engine: activeEngine, completion: complete)
        } else {
            // AI Edit with nothing selected behaves as Compose.
            ClaudePolish.compose(instruction, appName: sessionAppName, engine: activeEngine, completion: complete)
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
        let punctuate = sessionMode?.autoPunctuate ?? Settings.shared.autoPunctuate
        let lists = sessionMode?.smartLists ?? Settings.shared.smartLists
        opts.removeFillers = sessionMode?.removeFillers
        opts.autoPunctuate = punctuate
        opts.smartLists = lists
        opts.allowTerminalPunctuation = !searchField && punctuate
        opts.allowLists = !searchField && !codeSafe && lists
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
        TranscriptHistory.shared.add(TranscriptRecord(
            text: text,
            kind: historyKind(for: activeAction),
            appName: sessionAppName,
            bundleIdentifier: sessionApp,
            modeName: sessionMode?.name,
            duration: sessionDuration
        ))

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

    private func historyKind(for action: KeyAction) -> TranscriptRecord.Kind {
        switch action {
        case .dictate, .off: return .dictation
        case .aiRewrite: return .rewrite
        case .aiEdit, .aiCompose: return .compose
        case .aiAsk: return .ask
        case .aiDeep: return .research
        case .aiAgent: return .action
        }
    }
}
