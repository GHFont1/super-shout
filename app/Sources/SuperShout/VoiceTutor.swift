import Foundation

/// Background learning agent: periodically studies recent transcripts,
/// spots likely recognizer mistakes ("Taylor for our business" → "tailored
/// for our business"), and teaches the dictionary + vocabulary so future
/// dictation comes out right. High-confidence fixes only, capped per run,
/// never removes anything the user taught manually.
enum VoiceTutor {

    // MARK: - Transcript log

    private static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperShout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcripts.log")
    }

    /// Called on every delivered dictation/rewrite transcript.
    static func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return }  // fragments teach nothing
        let line = trimmed.replacingOccurrences(of: "\n", with: " ") + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        guard let data = try? Data(contentsOf: logURL), data.count > 200_000,
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        let kept = lines.suffix(400).joined(separator: "\n") + "\n"
        try? kept.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Study runs

    /// Runs at most once per interval; call freely.
    static func runIfDue() {
        guard Settings.shared.voiceTutorEnabled, ClaudePolish.isConfigured else { return }
        let last = Settings.shared.tutorLastRunAt
        guard Date().timeIntervalSince(last) > 6 * 3600 else { return }
        run()
    }

    static func run(completion: ((String) -> Void)? = nil) {
        Settings.shared.tutorLastRunAt = Date()

        // Seed from persisted history the first time so day-one dictations count.
        if (try? String(contentsOf: logURL, encoding: .utf8))?.isEmpty != false {
            for item in Settings.shared.historyStore.reversed() { record(item) }
        }
        guard let raw = try? String(contentsOf: logURL, encoding: .utf8), !raw.isEmpty else {
            completion?("Nothing to study yet")
            return
        }
        let transcripts = raw.split(separator: "\n").suffix(120).joined(separator: "\n")
        let dict = Settings.shared.dictionary.map { "\"\($0.key)\" → \"\($0.value)\"" }.joined(separator: ", ")
        let vocab = Settings.shared.vocabulary.joined(separator: ", ")

        let system = "You are the voice tutor for a dictation app. Study the user's recent transcripts and find words or "
            + "phrases the speech recognizer likely got WRONG — homophones (\"Taylor\" for \"tailored\"), mangled proper "
            + "nouns, misheard brands, acronyms spelled out wrong. Propose fixes ONLY when you are highly confident the "
            + "user meant something else; when in doubt, propose nothing. "
            + "Reply with ONLY valid JSON, no markdown fences: "
            + "{\"dictionary\": [{\"heard\": \"…\", \"corrected\": \"…\"}], \"vocabulary\": [\"…\"]}. "
            + "dictionary entries are literal phrase substitutions applied to all future transcripts — keep them 1-4 words, "
            + "specific and unambiguous; NEVER map a common word or phrase that is often correct as-is. "
            + "vocabulary is proper nouns/brands/acronyms the recognizer should expect. Do not repeat entries that already exist."
            + "\n\nExisting dictionary: \(dict.isEmpty ? "(none)" : dict)"
            + "\nExisting vocabulary: \(vocab)"

        ClaudePolish.tutorAnalyze(system: system, transcripts: transcripts) { reply in
            DispatchQueue.main.async {
                let summary = apply(reply)
                Settings.shared.tutorLastSummary = summary
                Log.write("VoiceTutor: \(summary)")
                completion?(summary)
            }
        }
    }

    /// Parses the JSON reply and applies capped, non-destructive additions.
    private static func apply(_ reply: String?) -> String {
        guard var text = reply else { return "Study run failed (provider unreachable)" }
        // Tolerate accidental code fences.
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Study run returned no usable result"
        }

        var added: [String] = []
        var dictStore = Settings.shared.dictionary
        if let pairs = json["dictionary"] as? [[String: String]] {
            for pair in pairs.prefix(8) {
                guard let heard = pair["heard"]?.trimmingCharacters(in: .whitespaces),
                      let corrected = pair["corrected"]?.trimmingCharacters(in: .whitespaces),
                      !heard.isEmpty, !corrected.isEmpty,
                      heard.lowercased() != corrected.lowercased(),
                      heard.split(separator: " ").count <= 4,
                      dictStore[heard] == nil,
                      dictStore.count < 500
                else { continue }
                dictStore[heard] = corrected
                added.append("\(heard) → \(corrected)")
            }
        }
        Settings.shared.dictionary = dictStore

        var vocabStore = Settings.shared.vocabulary
        var newTerms: [String] = []
        if let terms = json["vocabulary"] as? [String] {
            for term in terms.prefix(8) {
                let t = term.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, t.count <= 40,
                      !vocabStore.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame })
                else { continue }
                vocabStore.append(t)
                newTerms.append(t)
            }
        }
        Settings.shared.vocabulary = vocabStore

        if added.isEmpty && newTerms.isEmpty { return "Studied — nothing needed fixing" }
        var parts: [String] = []
        if !added.isEmpty { parts.append("learned \(added.count) fix\(added.count == 1 ? "" : "es"): \(added.joined(separator: "; "))") }
        if !newTerms.isEmpty { parts.append("new vocabulary: \(newTerms.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}
