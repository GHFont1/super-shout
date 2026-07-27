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

/// What holding a given key does.
enum KeyAction: String, CaseIterable, Codable {
    case dictate, aiEdit, aiCompose, off

    var displayName: String {
        switch self {
        case .dictate: return "Dictate"
        case .aiEdit: return "AI Edit Selection"
        case .aiCompose: return "AI Compose"
        case .off: return "Off"
        }
    }

    var needsAPIKey: Bool { self == .aiEdit || self == .aiCompose }
}

enum HoldKey: String, CaseIterable, Codable {
    case fn, rightCommand, rightOption

    var displayName: String {
        switch self {
        case .fn: return "fn (🌐)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
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
    /// Dictate; the remaining keys get AI Edit and AI Compose.
    func action(for key: HoldKey) -> KeyAction {
        if let stored = (d.dictionary(forKey: "keyActions") as? [String: String])?[key.rawValue],
           let action = KeyAction(rawValue: stored) {
            return action
        }
        if key == hotkey { return .dictate }
        let remaining = HoldKey.allCases.filter { $0 != hotkey }
        return key == remaining.first ? .aiEdit : .aiCompose
    }

    func setAction(_ action: KeyAction, for key: HoldKey) {
        var dict = (d.dictionary(forKey: "keyActions") as? [String: String]) ?? [:]
        dict[key.rawValue] = action.rawValue
        d.set(dict, forKey: "keyActions")
    }

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
        "UPC", "ASIN", "SKU", "GTIN", "EAN", "FBA", "FNSKU", "MPN", "MAP",
        "Amazon", "Shopify", "eBay", "Walmart", "Temu", "TikTok Shop", "Duoplane",
        "Great Call Athletics", "GCA", "Seller Central", "Notion", "Xero",
        "purchase order", "PO", "vendor SKU", "retailer SKU", "inventory feed"
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
