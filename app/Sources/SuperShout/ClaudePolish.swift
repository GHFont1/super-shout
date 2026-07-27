import Foundation

/// Claude API client for the three cloud features, all strictly opt-in with
/// the user's own key. Nothing leaves the machine unless a key is configured
/// and an AI mode is used.
enum ClaudePolish {

    /// Grammar/entity polish of a dictated transcript (used by the Dictate
    /// mode when "Polish transcripts" is on).
    static func polish(_ text: String, completion: @escaping (String?) -> Void) {
        send(
            system: "You clean up dictated text. Fix grammar, punctuation, and capitalization. Fix obviously misrecognized product, brand, and vehicle names (e.g. 'Genesis G7' is the 'Genesis G70'). Preserve the speaker's exact meaning, wording style, and tone. Never add content, never summarize, never answer questions in the text. Return only the cleaned text with no preamble.",
            user: text,
            maxTokens: 2048,
            timeout: 10,
            completion: completion
        )
    }

    /// AI Edit mode: applies a spoken instruction to the selected text.
    static func transform(selection: String, instruction: String, completion: @escaping (String?) -> Void) {
        send(
            system: "You rewrite text according to a spoken instruction. Apply the instruction faithfully. Keep everything the instruction does not cover unchanged, including line breaks and formatting. Return only the rewritten text with no preamble, no explanations, and no surrounding quotes. Never use em dashes.",
            user: "INSTRUCTION: \(instruction)\n\nTEXT:\n\(selection)",
            maxTokens: 4096,
            timeout: 25,
            completion: completion
        )
    }

    /// AI Compose mode: writes finished text from a spoken request.
    static func compose(_ instruction: String, completion: @escaping (String?) -> Void) {
        send(
            system: "You write text on the user's behalf from a spoken request. Return only the finished text, ready to be inserted exactly where they are typing. No preamble, no explanations, no surrounding quotes, no markdown unless the request implies it. Write naturally and concisely in the tone the request implies. Never use em dashes.",
            user: instruction,
            maxTokens: 4096,
            timeout: 25,
            completion: completion
        )
    }

    private static func send(system: String, user: String, maxTokens: Int, timeout: TimeInterval,
                             completion: @escaping (String?) -> Void) {
        let key = Settings.shared.anthropicAPIKey
        guard !key.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(nil)
            return
        }

        let body: [String: Any] = [
            "model": Settings.shared.polishModel,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["stop_reason"] as? String != "refusal",
                  let content = json["content"] as? [[String: Any]],
                  let textBlock = content.first(where: { $0["type"] as? String == "text" }),
                  let out = textBlock["text"] as? String,
                  !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                completion(nil)
                return
            }
            completion(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }
}
