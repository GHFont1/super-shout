import Foundation

/// Optional cloud polish step: sends the cleaned transcript to the Claude API
/// for grammar/tone refinement. Off by default; the app is fully functional
/// without it and nothing leaves the machine unless the user enables this.
enum ClaudePolish {
    static func polish(_ text: String, completion: @escaping (String?) -> Void) {
        let key = Settings.shared.anthropicAPIKey
        guard !key.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(nil)
            return
        }

        let body: [String: Any] = [
            "model": Settings.shared.polishModel,
            "max_tokens": 1024,
            "system": "You clean up dictated text. Fix grammar, punctuation, and capitalization. Preserve the speaker's exact meaning, wording style, and tone. Never add content, never summarize, never answer questions in the text. Return only the cleaned text with no preamble.",
            "messages": [["role": "user", "content": text]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
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
                  let polished = textBlock["text"] as? String,
                  !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                completion(nil)
                return
            }
            completion(polished.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }
}
