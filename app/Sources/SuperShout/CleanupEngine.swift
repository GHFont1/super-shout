import Foundation

/// Local, instant cleanup: filler removal, personal-dictionary replacement,
/// whitespace and capitalization tidy-up. No network involved.
enum CleanupEngine {
    private static let fillerPatterns: [String] = [
        #"(?i)\b(um+|uh+|uhm+|erm+|hmm+)\b[,]?\s*"#,
        #"(?i)\byou know[,]?\s+"#,
        #"(?i)\bi mean[,]?\s+"#,
        #"(?i)\b(like,)\s+"#
    ]

    /// Where the text is going changes what "clean" means: search queries
    /// aren't sentences, and terminals need literal text.
    struct CleanOptions {
        var allowTerminalPunctuation = true
        var allowLists = true
        var stripTrailingPeriod = false
        static let standard = CleanOptions()
    }

    static func clean(_ input: String, options: CleanOptions = .standard) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        if Settings.shared.removeFillers {
            for pattern in fillerPatterns {
                text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
        }

        for (spoken, replacement) in Settings.shared.dictionary {
            guard !spoken.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            text = text.replacingOccurrences(
                of: "(?i)\\b\(escaped)\\b",
                with: replacement,
                options: .regularExpression
            )
        }

        // Collapse doubled spaces left behind by removals, fix space-before-punctuation.
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }

        // Domain smarts: "2019 Genesis G7" → "2019 Genesis G70".
        if Settings.shared.smartEntities { text = EntityCorrector.correct(text) }

        if Settings.shared.autoPunctuate && options.allowTerminalPunctuation {
            text = ensureTerminalPunctuation(text)
        }
        if Settings.shared.smartLists && options.allowLists {
            text = ListFormatter.formatLists(in: text)
        }
        if options.stripTrailingPeriod, text.hasSuffix("."), !text.hasSuffix("..") {
            text = String(text.dropLast())
        }

        return text
    }

    /// Adds a period when the utterance ends without terminal punctuation.
    private static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        let terminals: Set<Character> = [".", "!", "?", ":", ";", ",", "\"", ")", "]", "-", "…"]
        if terminals.contains(last) { return text }
        // Don't punctuate a bare fragment that is clearly a single word command.
        return text + "."
    }
}

/// Turns spoken enumerations ("I need eggs, milk, and bread") into bulleted lists.
enum ListFormatter {
    private static let cueWords = "need|needs|buy|get|grab|pick up|want|wants|includes?|including|following|list of|items?|tasks?|todos?|steps?|bring"

    static func formatLists(in text: String) -> String {
        let sentences = splitSentences(text)
        var out: [String] = []
        for sentence in sentences {
            out.append(formatSentence(sentence) ?? sentence)
        }
        return out.joined(separator: " ")
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Returns a bulleted rewrite, or nil if the sentence isn't a list.
    private static func formatSentence(_ sentence: String) -> String? {
        let pattern = "(?i)^(.*?\\b(?:\(cueWords))\\b[^,]*?)\\s+((?:[^,]+,\\s*){2,}(?:and\\s+|or\\s+)?[^,.!?]+)[.!?]?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)),
              let leadRange = Range(m.range(at: 1), in: sentence),
              let itemsRange = Range(m.range(at: 2), in: sentence)
        else { return nil }

        let lead = String(sentence[leadRange]).trimmingCharacters(in: .whitespaces)
        let itemsBlob = String(sentence[itemsRange])

        let items = itemsBlob
            .components(separatedBy: ",")
            .map { part -> String in
                part.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"(?i)^(and|or)\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
            }
            .filter { !$0.isEmpty }

        guard items.count >= 3 else { return nil }

        let bullets = items.map { "- \($0)" }.joined(separator: "\n")
        let leadWithColon = lead.hasSuffix(":") ? lead : lead + ":"
        return "\n\(leadWithColon)\n\(bullets)"
    }
}
