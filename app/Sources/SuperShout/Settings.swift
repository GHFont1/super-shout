import Foundation

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

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var hotkey: HoldKey {
        get { HoldKey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }

    var removeFillers: Bool {
        get { d.object(forKey: "removeFillers") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeFillers") }
    }

    var aiPolishEnabled: Bool {
        get { d.bool(forKey: "aiPolishEnabled") }
        set { d.set(newValue, forKey: "aiPolishEnabled") }
    }

    var anthropicAPIKey: String {
        get { d.string(forKey: "anthropicAPIKey") ?? "" }
        set { d.set(newValue, forKey: "anthropicAPIKey") }
    }

    var polishModel: String {
        get { d.string(forKey: "polishModel") ?? "claude-opus-5" }
        set { d.set(newValue, forKey: "polishModel") }
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
}
