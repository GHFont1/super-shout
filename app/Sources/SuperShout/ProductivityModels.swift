import AppKit
import Foundation

enum SpeechEngineChoice: String, CaseIterable, Codable, Identifiable {
    case automatic, speechAnalyzer, legacy

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .speechAnalyzer: return "Apple Speech Analyzer (macOS 26+)"
        case .legacy: return "Classic Apple Speech"
        }
    }
}

enum HistoryRetention: String, CaseIterable, Codable, Identifiable {
    case thirtyDays, ninetyDays, oneYear, forever
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .oneYear: return "1 year"
        case .forever: return "Forever"
        }
    }
    var cutoff: Date? {
        let days: Int
        switch self {
        case .thirtyDays: days = 30
        case .ninetyDays: days = 90
        case .oneYear: days = 365
        case .forever: return nil
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}

struct VoiceSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var replacement: String
}

struct AppMode: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bundleIdentifiers: [String]
    var removeFillers: Bool
    var autoPunctuate: Bool
    var smartLists: Bool
    var aiPolish: Bool

    static let builtIns: [AppMode] = [
        AppMode(name: "Email", bundleIdentifiers: ["com.apple.mail", "com.microsoft.Outlook"], removeFillers: true, autoPunctuate: true, smartLists: true, aiPolish: true),
        AppMode(name: "Chat", bundleIdentifiers: ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS"], removeFillers: true, autoPunctuate: true, smartLists: false, aiPolish: false),
        AppMode(name: "Code & Terminal", bundleIdentifiers: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "com.microsoft.VSCode"], removeFillers: false, autoPunctuate: true, smartLists: false, aiPolish: false)
    ]
}

struct TranscriptRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case dictation, rewrite, compose, ask, research, action, meeting }

    var id = UUID()
    var createdAt = Date()
    var text: String
    var rawText: String?
    var kind: Kind
    var appName: String?
    var bundleIdentifier: String?
    var modeName: String?
    var duration: TimeInterval?
    var summary: String?
    var actionItems: [String] = []

    var searchableText: String {
        [text, rawText, summary, actionItems.joined(separator: " "), appName, modeName]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

enum SnippetExpander {
    static func expand(_ text: String, snippets: [VoiceSnippet]) -> String {
        var result = text
        for snippet in snippets where !snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let regex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])") else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: snippet.replacement))
        }
        return result
    }
}

enum AppModeResolver {
    static func resolve(bundleIdentifier: String?, modes: [AppMode]) -> AppMode? {
        guard let id = bundleIdentifier?.lowercased() else { return nil }
        return modes.first { mode in mode.bundleIdentifiers.contains { $0.lowercased() == id } }
    }
}
