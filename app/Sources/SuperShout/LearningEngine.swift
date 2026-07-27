import Foundation

/// Compares what Super Shout heard against what the user corrected it to, and
/// derives reusable dictionary entries + vocabulary terms from the difference.
enum LearningEngine {

    struct Lesson {
        var mappings: [(heard: String, corrected: String)] = []
        var newTerms: [String] = []
        var isEmpty: Bool { mappings.isEmpty && newTerms.isEmpty }
    }

    /// Word-level diff producing "heard X, meant Y" pairs.
    static func lesson(heard: String, corrected: String) -> Lesson {
        let a = tokenize(heard)
        let b = tokenize(corrected)
        var lesson = Lesson()

        for (oldRun, newRun) in alignedDifferences(a, b) {
            let from = oldRun.joined(separator: " ")
            let to = newRun.joined(separator: " ")
            guard !from.isEmpty, !to.isEmpty, from.lowercased() != to.lowercased() else { continue }
            // Only learn short, reusable substitutions — not whole rewritten sentences.
            guard oldRun.count <= 4, newRun.count <= 4 else { continue }
            lesson.mappings.append((heard: from, corrected: to))
            for word in newRun where isWorthLearning(word) {
                lesson.newTerms.append(word)
            }
        }

        // Terms present in the correction that we've never seen before.
        let heardLower = Set(a.map { $0.lowercased() })
        for word in b where isWorthLearning(word) && !heardLower.contains(word.lowercased()) {
            if !lesson.newTerms.contains(word) { lesson.newTerms.append(word) }
        }
        return lesson
    }

    static func apply(_ lesson: Lesson) {
        var dict = Settings.shared.dictionary
        for m in lesson.mappings { dict[m.heard] = m.corrected }
        Settings.shared.dictionary = dict

        var vocab = Settings.shared.vocabulary
        for term in lesson.newTerms where !vocab.contains(term) { vocab.append(term) }
        Settings.shared.vocabulary = vocab
    }

    /// Acronyms and capitalized proper nouns are the terms worth hinting.
    private static func isWorthLearning(_ word: String) -> Bool {
        let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count >= 2, cleaned.contains(where: \.isLetter) else { return false }
        if cleaned == cleaned.uppercased() { return true }               // UPC, ASIN, SKU
        if let f = cleaned.first, f.isUppercase { return true }          // Duoplane, Cranbarry
        return false
    }

    private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Returns pairs of differing runs between two token arrays, via LCS.
    private static func alignedDifferences(_ a: [String], _ b: [String]) -> [([String], [String])] {
        let n = a.count, m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i].lowercased() == b[j].lowercased()
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [([String], [String])] = []
        var i = 0, j = 0
        var oldRun: [String] = [], newRun: [String] = []

        func flush() {
            if !oldRun.isEmpty || !newRun.isEmpty {
                result.append((oldRun, newRun))
                oldRun = []; newRun = []
            }
        }

        while i < n && j < m {
            if a[i].lowercased() == b[j].lowercased() {
                flush(); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                oldRun.append(a[i]); i += 1
            } else {
                newRun.append(b[j]); j += 1
            }
        }
        while i < n { oldRun.append(a[i]); i += 1 }
        while j < m { newRun.append(b[j]); j += 1 }
        flush()
        return result
    }
}
