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

    /// True when the current provider can actually take a request.
    static var isConfigured: Bool {
        switch Settings.shared.aiProvider {
        case .claudeAPI: return !Settings.shared.anthropicAPIKey.isEmpty
        case .claudeCode: return cliPath("claude") != nil
        case .codexCLI: return cliPath("codex") != nil
        }
    }

    private static func send(system: String, user: String, maxTokens: Int, timeout: TimeInterval,
                             completion: @escaping (String?) -> Void) {
        switch Settings.shared.aiProvider {
        case .claudeAPI:
            sendAPI(system: system, user: user, maxTokens: maxTokens, timeout: timeout, completion: completion)
        case .claudeCode, .codexCLI:
            runCLI(system: system, user: user, completion: completion)
        }
    }

    // MARK: - CLI providers (reuse the plan sign-ins already on this Mac)

    private static let cliSearchPaths = [
        NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"
    ]

    private static func cliPath(_ name: String) -> String? {
        for dir in cliSearchPaths {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func runCLI(system: String, user: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let provider = Settings.shared.aiProvider
            let outFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("supershout-\(UUID().uuidString).txt")
            let process = Process()
            var stdinText: String
            switch provider {
            case .claudeCode:
                guard let bin = cliPath("claude") else { completion(nil); return }
                process.executableURL = URL(fileURLWithPath: bin)
                var args = ["-p", "--system-prompt", system]
                let model = Settings.shared.claudeCodeModel
                if !model.isEmpty { args += ["--model", model] }
                process.arguments = args
                stdinText = user
            case .codexCLI:
                guard let bin = cliPath("codex") else { completion(nil); return }
                process.executableURL = URL(fileURLWithPath: bin)
                var args = ["exec", "--skip-git-repo-check", "-o", outFile.path]
                let model = Settings.shared.codexModel
                if !model.isEmpty { args += ["-m", model] }
                process.arguments = args
                stdinText = system + "\n\n" + user
            case .claudeAPI:
                completion(nil); return
            }

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + cliSearchPaths.joined(separator: ":")
            process.environment = env

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            Log.write("CLI start: \(provider.rawValue) args=\(process.arguments ?? [])")
            do { try process.run() } catch {
                Log.write("CLI launch failed: \(error.localizedDescription)")
                completion(nil); return
            }
            stdin.fileHandleForWriting.write(Data(stdinText.utf8))
            stdin.fileHandleForWriting.closeFile()

            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            var result: String?
            if provider == .codexCLI {
                result = try? String(contentsOf: outFile, encoding: .utf8)
                try? FileManager.default.removeItem(at: outFile)
            } else {
                result = String(data: outData, encoding: .utf8)
            }
            let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus != 0 || trimmed?.isEmpty != false {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.write("CLI failed: status=\(process.terminationStatus) stderr=\(err.suffix(300))")
                completion(nil)
                return
            }
            Log.write("CLI done: \(trimmed?.count ?? 0) chars")
            completion(trimmed)
        }
    }

    private static func sendAPI(system: String, user: String, maxTokens: Int, timeout: TimeInterval,
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
