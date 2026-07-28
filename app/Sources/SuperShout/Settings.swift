import Foundation

/// Where AI requests go. The CLI providers reuse the plans already signed in
/// on this Mac (Claude Code → Claude subscription, Codex → ChatGPT plan) — no
/// API key involved.
enum AIProvider: String, CaseIterable, Codable {
    case claudeAPI, claudeCode, codexCLI

    var displayName: String {
        switch self {
        case .claudeAPI: return "Claude API key"
        case .claudeCode: return "Claude Code (your Claude plan)"
        case .codexCLI: return "Codex (your ChatGPT plan)"
        }
    }
}

/// Which model answers for a given key. `auto` follows the global provider.
enum EngineChoice: String, CaseIterable, Codable {
    case auto
    case apiHaiku, apiSonnet, apiOpus, apiFable
    case claudeCode, claudeCodeFable
    case codexSol

    var displayName: String {
        switch self {
        case .auto: return "Default engine"
        case .apiHaiku: return "Claude Haiku (fastest)"
        case .apiSonnet: return "Claude Sonnet"
        case .apiOpus: return "Claude Opus"
        case .apiFable: return "Claude Fable 5 (smartest)"
        case .claudeCode: return "Claude Code (plan default)"
        case .claudeCodeFable: return "Claude Code — Fable 5 (agent)"
        case .codexSol: return "ChatGPT — GPT-5.6-SOL"
        }
    }
}

/// What holding a given key does.
enum KeyAction: String, CaseIterable, Codable {
    case dictate, aiRewrite, aiEdit, aiCompose, aiDeep, aiAgent, aiAsk, off

    var displayName: String {
        switch self {
        case .dictate: return "Dictate"
        case .aiRewrite: return "AI Rewrite (your voice)"
        case .aiEdit: return "AI Edit Selection"
        case .aiCompose: return "AI Compose"
        case .aiDeep: return "AI Deep Research"
        case .aiAgent: return "AI Do (take action)"
        case .aiAsk: return "AI Ask (chat window)"
        case .off: return "Off"
        }
    }

    var needsAPIKey: Bool { self != .dictate && self != .off }
}

enum HoldKey: String, CaseIterable, Codable {
    case fn, rightCommand, rightOption, rightShift
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19

    /// The always-visible keys in Settings; the rest live under "More keys".
    static let primary: [HoldKey] = [.fn, .rightCommand, .rightOption]

    /// Modifier keys arrive as flagsChanged events; F-keys and Right ⇧-as-F
    /// arrive as keyDown/keyUp. Right Shift is a modifier.
    var isModifier: Bool {
        switch self {
        case .fn, .rightCommand, .rightOption, .rightShift: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .fn: return "fn (🌐)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightShift: return "Right ⇧"
        default: return rawValue.uppercased()
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightShift: return 60
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .f16: return 106
        case .f17: return 64
        case .f18: return 79
        case .f19: return 80
        }
    }
}

enum HUDPosition: String, CaseIterable, Codable {
    case bottomLeft, bottomCenter, bottomRight

    var displayName: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var hotkey: HoldKey {
        get { HoldKey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }

    /// Per-key mode assignment. Defaults: the legacy dictation hotkey stays
    /// Dictate; the remaining keys get AI Edit and AI Rewrite (Compose stays
    /// reachable — AI Edit with nothing selected composes).
    func action(for key: HoldKey) -> KeyAction {
        if let stored = (d.dictionary(forKey: "keyActions") as? [String: String])?[key.rawValue],
           let action = KeyAction(rawValue: stored) {
            return action
        }
        if key == hotkey { return .dictate }
        switch key {
        case .rightCommand: return .aiEdit
        case .rightOption: return .aiRewrite
        default: return .off  // extra keys start unbound
        }
    }

    func setAction(_ action: KeyAction, for key: HoldKey) {
        var dict = (d.dictionary(forKey: "keyActions") as? [String: String]) ?? [:]
        dict[key.rawValue] = action.rawValue
        d.set(dict, forKey: "keyActions")
    }

    /// Per-key model choice; `auto` follows the global provider setting.
    func engine(for key: HoldKey) -> EngineChoice {
        if let stored = (d.dictionary(forKey: "keyEngines") as? [String: String])?[key.rawValue],
           let engine = EngineChoice(rawValue: stored) {
            return engine
        }
        return .auto
    }

    func setEngine(_ engine: EngineChoice, for key: HoldKey) {
        var dict = (d.dictionary(forKey: "keyEngines") as? [String: String]) ?? [:]
        dict[key.rawValue] = engine.rawValue
        d.set(dict, forKey: "keyEngines")
    }

    /// How AI Rewrite should sound — editable in Settings, sent verbatim to
    /// the model as the author's style profile.
    var personalStyle: String {
        get {
            let stored = d.string(forKey: "personalStyle") ?? ""
            return stored.isEmpty ? Settings.defaultPersonalStyle : stored
        }
        set { d.set(newValue, forKey: "personalStyle") }
    }

    static let defaultPersonalStyle = """
        Short, direct, confident sentences. Plain everyday words, no corporate jargon, no hype. \
        Never use em dashes. Friendly but efficient — get to the point, then stop. \
        For emails: brief greeting, tight paragraphs, simple sign-off.
        """

    /// Facts about the speaker's business that ride along with every AI
    /// request, so "email Classic about the PO" needs no explanation.
    /// Empty by default — each install describes its own world. Nothing about
    /// any particular user or company ships in the binary.
    var businessContext: String {
        get { d.string(forKey: "businessContext") ?? "" }
        set { d.set(newValue, forKey: "businessContext") }
    }

    /// Example shown by the "Insert example" button, never active by itself.
    static let defaultBusinessContext = """
        The speaker is [your name], [role] at [company], a [what the company does]. \
        Key partners/vendors: [names]. Emails come from [address] and are signed "[signature]". \
        Terms the AI should know: [your acronyms and product names]. \
        Rules: [anything the AI must always or never do].
        """

    /// The key currently assigned to plain dictation, for UI copy.
    var dictateKeyDisplay: String {
        HoldKey.allCases.first { action(for: $0) == .dictate }?.displayName ?? "fn (🌐)"
    }

    var removeFillers: Bool {
        get { d.object(forKey: "removeFillers") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeFillers") }
    }

    var autoPunctuate: Bool {
        get { d.object(forKey: "autoPunctuate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoPunctuate") }
    }

    var smartLists: Bool {
        get { d.object(forKey: "smartLists") as? Bool ?? true }
        set { d.set(newValue, forKey: "smartLists") }
    }

    var smartSpacing: Bool {
        get { d.object(forKey: "smartSpacing") as? Bool ?? true }
        set { d.set(newValue, forKey: "smartSpacing") }
    }

    var aiPolishEnabled: Bool {
        get { d.bool(forKey: "aiPolishEnabled") }
        set { d.set(newValue, forKey: "aiPolishEnabled") }
    }

    var smartEntities: Bool {
        get { d.object(forKey: "smartEntities") as? Bool ?? true }
        set { d.set(newValue, forKey: "smartEntities") }
    }

    /// Quick-tap latches hands-free dictation. Off by default: accidental taps
    /// of fn were starting phantom dictations, so hold-to-talk only.
    var handsFreeTap: Bool {
        get { d.object(forKey: "handsFreeTap") as? Bool ?? false }
        set { d.set(newValue, forKey: "handsFreeTap") }
    }

    /// "New line", "new paragraph", "scratch that" spoken while dictating.
    var spokenCommands: Bool {
        get { d.object(forKey: "spokenCommands") as? Bool ?? true }
        set { d.set(newValue, forKey: "spokenCommands") }
    }

    /// Soft click when listening starts/stops, so you know it's live without
    /// looking at the Shout Bar.
    var soundCues: Bool {
        get { d.object(forKey: "soundCues") as? Bool ?? true }
        set { d.set(newValue, forKey: "soundCues") }
    }

    /// Cumulative seconds spent actually speaking, for the time-saved stat.
    var totalSecondsDictated: Double {
        get { d.double(forKey: "totalSecondsDictated") }
        set { d.set(newValue, forKey: "totalSecondsDictated") }
    }

    /// Where the Shout Bar sits on screen; it must never cover a Send button.
    var hudPosition: HUDPosition {
        get { HUDPosition(rawValue: d.string(forKey: "hudPosition") ?? "") ?? .bottomCenter }
        set { d.set(newValue.rawValue, forKey: "hudPosition") }
    }

    /// Background learning agent: studies transcripts and teaches the
    /// dictionary/vocabulary automatically.
    var voiceTutorEnabled: Bool {
        get { d.object(forKey: "voiceTutorEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "voiceTutorEnabled") }
    }

    var tutorLastRunAt: Date {
        get { d.object(forKey: "tutorLastRunAt") as? Date ?? .distantPast }
        set { d.set(newValue, forKey: "tutorLastRunAt") }
    }

    var tutorLastSummary: String {
        get { d.string(forKey: "tutorLastSummary") ?? "" }
        set { d.set(newValue, forKey: "tutorLastSummary") }
    }

    var totalWordsDictated: Int {
        get { d.integer(forKey: "totalWordsDictated") }
        set { d.set(newValue, forKey: "totalWordsDictated") }
    }

    /// Recent transcripts, persisted so history survives restarts.
    var historyStore: [String] {
        get { (d.array(forKey: "historyStore") as? [String]) ?? [] }
        set { d.set(newValue, forKey: "historyStore") }
    }

    /// Stored in the Keychain, never in plaintext UserDefaults. Reads migrate
    /// any legacy UserDefaults value once, then remove it.
    var anthropicAPIKey: String {
        get {
            if let key = Keychain.get("anthropicAPIKey") { return key }
            if let legacy = d.string(forKey: "anthropicAPIKey"), !legacy.isEmpty {
                Keychain.set("anthropicAPIKey", legacy)
                d.removeObject(forKey: "anthropicAPIKey")
                return legacy
            }
            return ""
        }
        set {
            Keychain.set("anthropicAPIKey", newValue)
            d.removeObject(forKey: "anthropicAPIKey")
        }
    }

    var polishModel: String {
        get { d.string(forKey: "polishModel") ?? "claude-opus-5" }
        set { d.set(newValue, forKey: "polishModel") }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .claudeAPI }
        set { d.set(newValue.rawValue, forKey: "aiProvider") }
    }

    /// Model override for the Claude Code CLI; empty = its default.
    var claudeCodeModel: String {
        get { d.string(forKey: "claudeCodeModel") ?? "" }
        set { d.set(newValue, forKey: "claudeCodeModel") }
    }

    /// Model for the Codex CLI; empty = its default.
    var codexModel: String {
        get { d.string(forKey: "codexModel") ?? "gpt-5.6-sol" }
        set { d.set(newValue, forKey: "codexModel") }
    }

    var language: String {
        get { d.string(forKey: "language") ?? "en-US" }
        set { d.set(newValue, forKey: "language") }
    }

    /// Empty follows the macOS system default. A saved UID keeps Super Shout on
    /// the intended USB microphone even when a webcam becomes the default.
    var audioInputUID: String {
        get { d.string(forKey: "audioInputUID") ?? "" }
        set { d.set(newValue, forKey: "audioInputUID") }
    }

    /// Phone speakers and conference calls often arrive much quieter than a
    /// person speaking directly into the mic. Normalize only quiet, non-silent
    /// buffers before they reach Speech.framework.
    var enhanceQuietAudio: Bool {
        get { d.object(forKey: "enhanceQuietAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "enhanceQuietAudio") }
    }

    var speechEngine: SpeechEngineChoice {
        get { SpeechEngineChoice(rawValue: d.string(forKey: "speechEngine") ?? "") ?? .automatic }
        set { d.set(newValue.rawValue, forKey: "speechEngine") }
    }

    var voiceSnippets: [VoiceSnippet] {
        get { decode([VoiceSnippet].self, key: "voiceSnippets") ?? [] }
        set { encode(newValue, key: "voiceSnippets") }
    }

    var appModes: [AppMode] {
        get { decode([AppMode].self, key: "appModes") ?? AppMode.builtIns }
        set { encode(newValue, key: "appModes") }
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    // Personal dictionary: spoken (case-insensitive) -> replacement
    var dictionary: [String: String] {
        get { (d.dictionary(forKey: "personalDictionary") as? [String: String]) ?? [:] }
        set { d.set(newValue, forKey: "personalDictionary") }
    }

    /// Terms fed to the speech recognizer as contextual hints so it spells them
    /// correctly the first time (acronyms, brands, jargon).
    var vocabulary: [String] {
        get { (d.array(forKey: "vocabulary") as? [String]) ?? Settings.defaultVocabulary }
        set { d.set(newValue, forKey: "vocabulary") }
    }

    static let defaultVocabulary = [
        "UPC", "ASIN", "SKU", "GTIN", "EAN", "FBA", "FNSKU", "MPN",
        "Amazon", "Shopify", "eBay", "Walmart", "Seller Central",
        "purchase order", "PO", "vendor SKU", "inventory feed"
    ]

    /// Everything worth hinting to the recognizer: vocabulary plus both sides of
    /// the personal dictionary.
    var contextualStrings: [String] {
        var terms = Set(vocabulary)
        for (spoken, replacement) in dictionary {
            terms.insert(spoken)
            terms.insert(replacement)
        }
        return Array(terms).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
