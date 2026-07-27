import Foundation

/// Decides how a new dictation should join whatever is already at the cursor:
/// whether to prepend a space, and whether the first word starts a new sentence
/// (capitalized) or continues the previous one (lowercased).
enum SpacingEngine {

    /// Characters after which we must NOT insert a space.
    private static let noSpaceAfter: Set<Character> = [
        " ", "\n", "\t", "(", "[", "{", "\"", "'", "“", "‘", "-", "—", "/", "@", "#", "$", "*", "_", "~", "<", "="
    ]

    /// Characters that end a sentence — the next dictation is a fresh sentence.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", "\n"]

    /// Words that keep their capital letter even mid-sentence.
    private static func keepsCapital(_ word: String) -> Bool {
        if word == "I" || word.hasPrefix("I'") { return true }
        // All-caps acronyms (NFL, GCA, UPC…)
        if word.count > 1 && word == word.uppercased() && word.contains(where: \.isLetter) { return true }
        // Anything the user taught us as a proper noun
        for replacement in Settings.shared.dictionary.values
        where replacement.split(separator: " ").first.map(String.init) == word {
            return true
        }
        return false
    }

    /// Joins `text` onto the existing content, given the character before the caret.
    /// `previous` is nil when the caret sits at the very start of an empty field.
    static func join(_ text: String, after previous: Character?) -> String {
        var out = text
        guard let previous else {
            // Start of a field: fresh sentence, no leading space.
            return capitalizeFirst(out)
        }

        let startsNewSentence = sentenceEnders.contains(previous)
        let needsSpace = !noSpaceAfter.contains(previous)

        if startsNewSentence {
            out = capitalizeFirst(out)
        } else if previous.isLetter || previous.isNumber || previous == "," || previous == ";" {
            out = lowercaseFirstIfSafe(out)
        }

        if needsSpace {
            out = " " + out
        }
        return out
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first, f.isLowercase else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private static func lowercaseFirstIfSafe(_ s: String) -> String {
        guard let firstWord = s.split(separator: " ").first.map(String.init),
              let f = s.first, f.isUppercase,
              !keepsCapital(firstWord)
        else { return s }
        return f.lowercased() + s.dropFirst()
    }
}
