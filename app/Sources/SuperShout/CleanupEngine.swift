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

    static func clean(_ input: String) -> String {
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
        return text
    }
}
