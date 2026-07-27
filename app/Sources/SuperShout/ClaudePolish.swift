import Foundation

/// Claude API client for the three cloud features, all strictly opt-in with
/// the user's own key. Nothing leaves the machine unless a key is configured
/// and an AI mode is used.
enum ClaudePolish {

    /// Grammar/entity polish of a dictated transcript (used by the Dictate
    /// mode when "Polish transcripts" is on).
    static func polish(_ text: String, appName: String? = nil, completion: @escaping (String?) -> Void) {
        send(
            system: "You clean up dictated text. Fix grammar, punctuation, and capitalization. Fix obviously misrecognized product, brand, and vehicle names (e.g. 'Genesis G7' is the 'Genesis G70'). Preserve the speaker's exact meaning, wording style, and tone. Never add content, never summarize, never answer questions in the text. Return only the cleaned text with no preamble."
                + appContextLine(appName),
            user: text,
            maxTokens: 2048,
            timeout: 10,
            fast: true,
            completion: completion
        )
    }

    /// AI Rewrite mode: the spoken transcript is retyped as finished writing
    /// in the user's own voice, formatted for the destination (an email gets
    /// email structure, a chat message stays a chat message).
    static func rewrite(_ transcript: String, appName: String? = nil, completion: @escaping (String?) -> Void) {
        let style = Settings.shared.personalStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        send(
            system: "You turn a raw spoken transcript into finished writing in the speaker's own voice. "
                + "Say everything they meant to say — keep every point, name, number, and commitment — but write it the way they would type it: "
                + "drop the rambling, false starts, and repeated thoughts, and organize it cleanly. "
                + "Format for the destination: if it reads as an email, structure it as one (greeting if implied, short paragraphs, sign-off); "
                + "if it's a chat message or note, keep it as one. Never add facts, opinions, or promises they didn't say. "
                + "Never use em dashes. Return only the finished text with no preamble and no surrounding quotes."
                + (style.isEmpty ? "" : "\n\nThe speaker's writing style: \(style)")
                + appContextLine(appName)
                + businessContextBlock(),
            user: transcript,
            maxTokens: 4096,
            timeout: 25,
            completion: completion
        )
    }

    /// AI Edit mode: applies a spoken instruction to the selected text.
    static func transform(selection: String, instruction: String, completion: @escaping (String?) -> Void) {
        send(
            system: "You rewrite text according to a spoken instruction. Apply the instruction faithfully. Keep everything the instruction does not cover unchanged, including line breaks and formatting. Return only the rewritten text with no preamble, no explanations, and no surrounding quotes. Never use em dashes."
                + businessContextBlock(),
            user: "INSTRUCTION: \(instruction)\n\nTEXT:\n\(selection)",
            maxTokens: 4096,
            timeout: 25,
            completion: completion
        )
    }

    /// AI Compose mode: writes finished text from a spoken request.
    static func compose(_ instruction: String, appName: String? = nil, completion: @escaping (String?) -> Void) {
        send(
            system: "You write text on the user's behalf from a spoken request. Return only the finished text, ready to be inserted exactly where they are typing. No preamble, no explanations, no surrounding quotes, no markdown unless the request implies it. Write naturally and concisely in the tone the request implies. Never use em dashes."
                + appContextLine(appName)
                + businessContextBlock(),
            user: instruction,
            maxTokens: 4096,
            timeout: 25,
            completion: completion
        )
    }

    /// AI Deep Research mode: a full agentic Claude Code run that looks facts
    /// up first (files, MCP servers, local tooling) and then writes the
    /// deliverable. Minutes, not seconds — runs in the background and the
    /// result is handed over via clipboard + history.
    static func deepResearch(_ instruction: String, completion: @escaping (String?) -> Void) {
        let system = "You are a research assistant running on the user's own Mac with access to their files and tools. "
            + "First use your available tools (project files, MCP servers, local scripts, read-only shell commands) to look up the facts the request needs. "
            + "Research is read-only: never send emails or messages, never place or cancel orders, never modify data — the user reviews and sends everything themselves. "
            + "Then produce the final deliverable the request asks for (usually an email or message body, sometimes a summary or report). "
            + "Return ONLY that final text, ready to paste — no explanation of your research process, no preamble. Never use em dashes."
            + businessContextBlock()
        runDeepClaude(system: system, user: instruction, completion: completion)
    }

    static var isDeepAvailable: Bool { cliPath("claude") != nil }

    /// AI Ask mode: answers a spoken question in the chat window. The
    /// transcript carries the whole conversation so follow-ups have context.
    /// With the Claude Code provider it may use tools (web search, local
    /// lookups) for current or local questions.
    static func ask(_ transcript: String, completion: @escaping (String?) -> Void) {
        let system = "You are a helpful chat assistant. Answer the user's latest message directly and completely, "
            + "the way a chat assistant would. Conversational plain text; short lists are fine. "
            + "If the question needs current or local information and you have tools available (web search, shell), use them. "
            + "Never use em dashes."
            + businessContextBlock()
        switch Settings.shared.aiProvider {
        case .claudeCode:
            runDeepClaude(system: system, user: transcript, completion: completion)
        case .claudeAPI:
            sendAPI(system: system, user: transcript, maxTokens: 4096, timeout: 30,
                    model: Settings.shared.polishModel, completion: completion)
        case .codexCLI:
            runCLI(system: system, user: transcript, completion: completion)
        }
    }

    /// AI Do mode: a Claude Code agent run that CARRIES OUT the spoken request
    /// (file the selection in Notion, save a note, run a lookup-and-record) and
    /// reports what it did. Guardrailed: drafts only for outbound messages,
    /// never touches customer orders, no destructive changes.
    static func agentAct(instruction: String, selection: String?, completion: @escaping (String?) -> Void) {
        let system = "You are an assistant with hands, running on the user's own Mac via Claude Code with access to their files, "
            + "MCP servers, and shell. Carry out the spoken request now — actually do it, don't describe how. "
            + "If SELECTED TEXT is provided, the request refers to it. "
            + "Hard rules that override the request: never send emails or messages (create drafts instead and say so); "
            + "never cancel, refund, or modify customer or marketplace orders; "
            + "never make destructive or irreversible changes that were not explicitly requested. "
            + "When finished, return a 1-3 sentence report of exactly what you did, naming anything you created (with links or paths). "
            + "If you could not complete it, say exactly why and what is needed. Never use em dashes."
            + businessContextBlock()
        var user = instruction
        if let selection, !selection.isEmpty {
            user += "\n\nSELECTED TEXT:\n" + selection
        }
        runDeepClaude(system: system, user: user, completion: completion)
    }

    /// Dedicated deep runner: always the Claude Code CLI (agentic, tool-using),
    /// from $HOME so global CLAUDE.md and MCP config load, with a 10 min cap.
    private static func runDeepClaude(system: String, user: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bin = cliPath("claude") else { completion(nil); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            var args = ["-p", "--permission-mode", "bypassPermissions", "--append-system-prompt", system]
            let model = Settings.shared.claudeCodeModel
            if !model.isEmpty { args += ["--model", model] }
            process.arguments = args
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + cliSearchPaths.joined(separator: ":")
            process.environment = env

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            Log.write("DEEP start: args=\(args)")
            do { try process.run() } catch {
                Log.write("DEEP launch failed: \(error.localizedDescription)")
                completion(nil); return
            }
            stdin.fileHandleForWriting.write(Data(user.utf8))
            stdin.fileHandleForWriting.closeFile()

            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            let trimmed = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus != 0 || trimmed?.isEmpty != false {
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Log.write("DEEP failed: status=\(process.terminationStatus) stderr=\(err.suffix(300))")
                completion(nil)
                return
            }
            Log.write("DEEP done: \(trimmed?.count ?? 0) chars")
            completion(trimmed)
        }
    }

    /// Light context awareness: the target app shapes tone (a Slack message
    /// reads differently from a Mail draft) without any screen capture.
    private static func appContextLine(_ appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return "" }
        return " The text will be inserted into the app \"\(appName)\" — match the tone and formatting conventions people use there."
    }

    /// The speaker's standing business facts (who their vendors are, how they
    /// sign emails) — so "email Classic about the PO" needs no explanation.
    private static func businessContextBlock() -> String {
        let ctx = Settings.shared.businessContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ctx.isEmpty else { return "" }
        return "\n\nStanding context about the speaker and their business — use it to resolve names, "
            + "facts, and tone, and follow any rules it states. Never mention that you were given it:\n" + ctx
    }

    /// True when the current provider can actually take a request.
    static var isConfigured: Bool {
        switch Settings.shared.aiProvider {
        case .claudeAPI: return !Settings.shared.anthropicAPIKey.isEmpty
        case .claudeCode: return cliPath("claude") != nil
        case .codexCLI: return cliPath("codex") != nil
        }
    }

    /// `fast` routes to the quickest model (polish is grammar fixup — small
    /// models are plenty); AI Edit/Compose keep the user's chosen model.
    private static func send(system: String, user: String, maxTokens: Int, timeout: TimeInterval,
                             fast: Bool = false, completion: @escaping (String?) -> Void) {
        switch Settings.shared.aiProvider {
        case .claudeAPI:
            sendAPI(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                    model: fast ? "claude-haiku-4-5" : Settings.shared.polishModel,
                    completion: completion)
        case .claudeCode, .codexCLI:
            runCLI(system: system, user: user, fast: fast, completion: completion)
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

    private static func runCLI(system: String, user: String, fast: Bool = false,
                               completion: @escaping (String?) -> Void) {
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
                let model = fast ? "haiku" : Settings.shared.claudeCodeModel
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
                                model: String, completion: @escaping (String?) -> Void) {
        let key = Settings.shared.anthropicAPIKey
        guard !key.isEmpty, let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(nil)
            return
        }

        let body: [String: Any] = [
            "model": model,
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
