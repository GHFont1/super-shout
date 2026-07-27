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
